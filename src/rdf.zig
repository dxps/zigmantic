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

const StringId = enum(u32) { _ };
pub const TermId = enum(u32) { _ };

pub const Error = std.mem.Allocator.Error || error{
    InvalidBlankNodeIdentifier,
    InvalidGraphName,
    InvalidIri,
    InvalidLiteral,
    InvalidLanguageTag,
    InvalidPredicate,
    InvalidSubject,
    InvalidUtf8,
    UnknownTerm,
};

const Literal = struct {
    lexical_form: StringId,
    datatype: StringId,
    language: ?StringId = null,
};

const Term = union(enum) {
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

    /// Interns a borrowed RDF term value without exposing the pool's storage format.
    /// A language-tagged value must use the required `rdf:langString` datatype.
    pub fn internView(self: *TermPool, value: TermView) Error!TermId {
        return switch (value) {
            .named_node => |iri| self.internNamedNode(iri),
            .blank_node => |identifier| self.internBlankNode(identifier),
            .literal => |literal| if (literal.language) |language|
                if (std.mem.eql(u8, literal.datatype, rdf_lang_string))
                    self.internLanguageLiteral(literal.lexical_form, language)
                else
                    error.InvalidLiteral
            else
                self.internTypedLiteral(literal.lexical_form, literal.datatype),
        };
    }

    fn get(self: *const TermPool, id: TermId) ?Term {
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

    /// Compares RDF terms by value, including when their identifiers belong to
    /// different pools.
    pub fn eqlTerm(
        self: *const TermPool,
        id: TermId,
        other: *const TermPool,
        other_id: TermId,
    ) Error!bool {
        const left = self.view(id) orelse return error.UnknownTerm;
        const right = other.view(other_id) orelse return error.UnknownTerm;

        return switch (left) {
            .named_node => |value| switch (right) {
                .named_node => |other_value| std.mem.eql(u8, value, other_value),
                else => false,
            },
            .blank_node => |value| switch (right) {
                .blank_node => |other_value| std.mem.eql(u8, value, other_value),
                else => false,
            },
            .literal => |value| switch (right) {
                .literal => |other_value| literalViewEql(value, other_value),
                else => false,
            },
        };
    }

    /// Returns a deterministic hash of the RDF term value. Equal terms from
    /// different pools have the same hash.
    pub fn hashTerm(self: *const TermPool, id: TermId) Error!u64 {
        const value = self.view(id) orelse return error.UnknownTerm;
        var hash = Fnv1a64.init;

        switch (value) {
            .named_node => |iri| {
                hash.addByte(0);
                hash.addSlice(iri);
            },
            .blank_node => |identifier| {
                hash.addByte(1);
                hash.addSlice(identifier);
            },
            .literal => |literal| {
                hash.addByte(2);
                hash.addSlice(literal.lexical_form);
                hash.addSlice(literal.datatype);
                if (literal.language) |language| {
                    hash.addByte(1);
                    hash.addSlice(language);
                } else {
                    hash.addByte(0);
                }
            },
        }
        return hash.value;
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

pub const TriplePattern = struct {
    subject: ?TermId = null,
    predicate: ?TermId = null,
    object: ?TermId = null,

    fn matches(self: TriplePattern, triple: Triple) bool {
        return (self.subject == null or self.subject.? == triple.subject) and
            (self.predicate == null or self.predicate.? == triple.predicate) and
            (self.object == null or self.object.? == triple.object);
    }
};

pub const TripleIterator = struct {
    triples: []const Triple,
    pattern: TriplePattern,
    index: usize = 0,

    pub fn next(self: *TripleIterator) ?Triple {
        while (self.index < self.triples.len) {
            const triple = self.triples[self.index];
            self.index += 1;
            if (self.pattern.matches(triple)) return triple;
        }
        return null;
    }
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

pub const QuadPattern = struct {
    subject: ?TermId = null,
    predicate: ?TermId = null,
    object: ?TermId = null,
    graph_name: ?GraphName = null,

    fn matches(self: QuadPattern, quad: Quad) bool {
        return (self.subject == null or self.subject.? == quad.subject) and
            (self.predicate == null or self.predicate.? == quad.predicate) and
            (self.object == null or self.object.? == quad.object) and
            (self.graph_name == null or std.meta.eql(self.graph_name.?, quad.graph_name));
    }
};

pub const QuadIterator = struct {
    quads: []const Quad,
    pattern: QuadPattern,
    index: usize = 0,

    pub fn next(self: *QuadIterator) ?Quad {
        while (self.index < self.quads.len) {
            const quad = self.quads[self.index];
            self.index += 1;
            if (self.pattern.matches(quad)) return quad;
        }
        return null;
    }
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

    /// Removes an exact pool-local triple while preserving the order of the remaining
    /// triples. Returns false when the triple is absent.
    pub fn remove(self: *Graph, triple: Triple) bool {
        for (self.triples.items, 0..) |existing, index| {
            if (std.meta.eql(existing, triple)) {
                _ = self.triples.orderedRemove(index);
                return true;
            }
        }
        return false;
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

    pub fn iterator(self: *const Graph, pattern: TriplePattern) TripleIterator {
        return .{ .triples = self.triples.items, .pattern = pattern };
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

    /// Removes an exact pool-local quad while preserving the order of the remaining
    /// quads. Returns false when the quad is absent.
    pub fn remove(self: *Dataset, quad: Quad) bool {
        for (self.quads.items, 0..) |existing, index| {
            if (std.meta.eql(existing, quad)) {
                _ = self.quads.orderedRemove(index);
                return true;
            }
        }
        return false;
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

    pub fn iterator(self: *const Dataset, pattern: QuadPattern) QuadIterator {
        return .{ .quads = self.quads.items, .pattern = pattern };
    }
};

const Fnv1a64 = struct {
    const init: Fnv1a64 = .{};
    const prime: u64 = 0x00000100000001B3;

    value: u64 = 0xCBF29CE484222325,

    fn addByte(self: *Fnv1a64, byte: u8) void {
        self.value = (self.value ^ byte) *% prime;
    }

    fn addSlice(self: *Fnv1a64, value: []const u8) void {
        var length: u64 = @intCast(value.len);
        for (0..@sizeOf(u64)) |_| {
            self.addByte(@truncate(length));
            length >>= 8;
        }
        for (value) |byte| self.addByte(byte);
    }
};

fn literalViewEql(left: LiteralView, right: LiteralView) bool {
    if (!std.mem.eql(u8, left.lexical_form, right.lexical_form)) return false;
    if (!std.mem.eql(u8, left.datatype, right.datatype)) return false;
    if (left.language == null or right.language == null) return left.language == null and right.language == null;
    return std.mem.eql(u8, left.language.?, right.language.?);
}

/// Validates that all identifiers belong to `pool` and occupy legal RDF triple
/// positions. This does not insert the triple into a container.
pub fn validateTriple(pool: *const TermPool, triple: Triple) Error!void {
    const subject = pool.get(triple.subject) orelse return error.UnknownTerm;
    const predicate = pool.get(triple.predicate) orelse return error.UnknownTerm;
    _ = pool.get(triple.object) orelse return error.UnknownTerm;

    switch (subject) {
        .named_node, .blank_node => {},
        .literal => return error.InvalidSubject,
    }
    if (predicate != .named_node) return error.InvalidPredicate;
}

/// Validates that a graph name is the default graph or a pool-owned IRI or blank node.
pub fn validateGraphName(pool: *const TermPool, graph_name: GraphName) Error!void {
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
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
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

test "term views can be safely interned without exposing storage identifiers" {
    var source = TermPool.init(std.testing.allocator);
    defer source.deinit();
    var target = TermPool.init(std.testing.allocator);
    defer target.deinit();

    const source_literal = try source.internLanguageLiteral("salut", "RO-Latn");
    const copied = try target.internView(source.view(source_literal).?);
    try std.testing.expect(try source.eqlTerm(source_literal, &target, copied));

    try std.testing.expectError(error.InvalidLiteral, target.internView(.{ .literal = .{
        .lexical_form = "invalid",
        .datatype = xsd_string,
        .language = "en",
    } }));
}

test "term equality and hashing are stable across pools" {
    var left = TermPool.init(std.testing.allocator);
    defer left.deinit();
    var right = TermPool.init(std.testing.allocator);
    defer right.deinit();

    const left_iri = try left.internNamedNode("https://example.com/resource");
    const right_iri = try right.internNamedNode("https://example.com/resource");
    const blank = try right.internBlankNode("https://example.com/resource");
    try std.testing.expect(try left.eqlTerm(left_iri, &right, right_iri));
    try std.testing.expect(!(try left.eqlTerm(left_iri, &right, blank)));
    try std.testing.expectEqual(try left.hashTerm(left_iri), try right.hashTerm(right_iri));

    const left_literal = try left.internLanguageLiteral("salut", "RO");
    const right_literal = try right.internLanguageLiteral("salut", "ro");
    try std.testing.expect(try left.eqlTerm(left_literal, &right, right_literal));
    try std.testing.expectEqual(try left.hashTerm(left_literal), try right.hashTerm(right_literal));

    const unknown: TermId = @fromBackingInt(999);
    try std.testing.expectError(error.UnknownTerm, left.hashTerm(unknown));
    try std.testing.expectError(error.UnknownTerm, left.eqlTerm(unknown, &right, right_iri));
}

test "term constructors reject structurally invalid values" {
    var pool = TermPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("relative/path"));
    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("https://example.com/a b"));
    try std.testing.expectError(error.InvalidBlankNodeIdentifier, pool.internBlankNode(""));
    try std.testing.expectError(error.InvalidLanguageTag, pool.internLanguageLiteral("hello", "en--GB"));
}

test "term constructors preserve RDF term distinctions at edge cases" {
    var pool = TermPool.init(std.testing.allocator);
    defer pool.deinit();

    const empty = try pool.internSimpleLiteral("");
    const unicode = try pool.internLanguageLiteral("Bună ziua 👋", "RO-latn");
    const integer_one = try pool.internTypedLiteral("1", xsd_namespace ++ "integer");
    const decimal_one = try pool.internTypedLiteral("1", xsd_namespace ++ "decimal");

    try std.testing.expect(!try pool.eqlTerm(empty, &pool, unicode));
    try std.testing.expect(!try pool.eqlTerm(integer_one, &pool, decimal_one));
    try std.testing.expectEqualStrings(
        "ro-latn",
        pool.view(unicode).?.literal.language.?,
    );

    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("1invalid:scheme"));
    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("https://example.com/<bad>"));
    try std.testing.expectError(error.InvalidBlankNodeIdentifier, pool.internBlankNode("two words"));
    try std.testing.expectError(error.InvalidLanguageTag, pool.internLanguageLiteral("hello", "1"));
    try std.testing.expectError(error.InvalidLanguageTag, pool.internLanguageLiteral("hello", "-en"));
    try std.testing.expectError(error.InvalidLanguageTag, pool.internLanguageLiteral("hello", "en-"));

    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, pool.internSimpleLiteral(&invalid_utf8));
    try std.testing.expectError(error.InvalidIri, pool.internNamedNode(&invalid_utf8));
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

test "graph iterator filters without allocating" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const alice = try graph.terms.internNamedNode("https://example.com/alice");
    const bob = try graph.terms.internNamedNode("https://example.com/bob");
    const name = try graph.terms.internNamedNode("https://example.com/name");
    const alice_name = try graph.terms.internSimpleLiteral("Alice");
    const bob_name = try graph.terms.internSimpleLiteral("Bob");
    _ = try graph.add(.{ .subject = alice, .predicate = name, .object = alice_name });
    _ = try graph.add(.{ .subject = bob, .predicate = name, .object = bob_name });

    var matches = graph.iterator(.{ .subject = alice });
    try std.testing.expectEqual(
        Triple{ .subject = alice, .predicate = name, .object = alice_name },
        matches.next().?,
    );
    try std.testing.expectEqual(@as(?Triple, null), matches.next());
}

test "graph removal preserves remaining statement order" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const subject = try graph.terms.internNamedNode("https://example.com/subject");
    const predicate = try graph.terms.internNamedNode("https://example.com/predicate");
    const first = try graph.terms.internSimpleLiteral("first");
    const second = try graph.terms.internSimpleLiteral("second");
    const first_triple = Triple{ .subject = subject, .predicate = predicate, .object = first };
    const second_triple = Triple{ .subject = subject, .predicate = predicate, .object = second };
    _ = try graph.add(first_triple);
    _ = try graph.add(second_triple);

    try std.testing.expect(graph.remove(first_triple));
    try std.testing.expect(!graph.remove(first_triple));
    try std.testing.expectEqual(@as(usize, 1), graph.len());
    try std.testing.expectEqual(second_triple, graph.items()[0]);
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

test "dataset iterator distinguishes default and named graphs" {
    var dataset = Dataset.init(std.testing.allocator);
    defer dataset.deinit();

    const subject = try dataset.terms.internNamedNode("https://example.com/subject");
    const predicate = try dataset.terms.internNamedNode("https://example.com/predicate");
    const object = try dataset.terms.internSimpleLiteral("object");
    const graph_name = try dataset.terms.internNamedNode("https://example.com/graph");
    const triple = Triple{ .subject = subject, .predicate = predicate, .object = object };
    _ = try dataset.addDefault(triple);
    _ = try dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph_name },
    });

    var default_matches = dataset.iterator(.{ .graph_name = .default });
    try std.testing.expectEqual(GraphName.default, default_matches.next().?.graph_name);
    try std.testing.expectEqual(@as(?Quad, null), default_matches.next());

    var named_matches = dataset.iterator(.{ .graph_name = .{ .named = graph_name } });
    try std.testing.expectEqual(GraphName{ .named = graph_name }, named_matches.next().?.graph_name);
    try std.testing.expectEqual(@as(?Quad, null), named_matches.next());
}

test "dataset removal preserves remaining quad order" {
    var dataset = Dataset.init(std.testing.allocator);
    defer dataset.deinit();

    const subject = try dataset.terms.internNamedNode("https://example.com/subject");
    const predicate = try dataset.terms.internNamedNode("https://example.com/predicate");
    const object = try dataset.terms.internNamedNode("https://example.com/object");
    const graph_name = try dataset.terms.internNamedNode("https://example.com/graph");
    const default_quad = Quad{ .subject = subject, .predicate = predicate, .object = object };
    const named_quad = Quad{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph_name },
    };
    _ = try dataset.add(default_quad);
    _ = try dataset.add(named_quad);

    try std.testing.expect(dataset.remove(default_quad));
    try std.testing.expect(!dataset.remove(default_quad));
    try std.testing.expectEqual(@as(usize, 1), dataset.len());
    try std.testing.expectEqual(named_quad, dataset.items()[0]);
}

fn exerciseGraphAllocations(allocator: std.mem.Allocator) !void {
    var graph = Graph.init(allocator);
    defer graph.deinit();

    const subject = try graph.terms.internNamedNode("https://example.com/subject");
    const predicate = try graph.terms.internNamedNode("https://example.com/predicate");
    const object = try graph.terms.internLanguageLiteral("Bună", "RO");
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = object });
}

fn exerciseDatasetAllocations(allocator: std.mem.Allocator) !void {
    var dataset = Dataset.init(allocator);
    defer dataset.deinit();

    const subject = try dataset.terms.internBlankNode("subject");
    const predicate = try dataset.terms.internNamedNode("https://example.com/predicate");
    const object = try dataset.terms.internTypedLiteral("42", xsd_namespace ++ "integer");
    const graph_name = try dataset.terms.internNamedNode("https://example.com/graph");
    _ = try dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph_name },
    });
}

test "RDF owners handle every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGraphAllocations,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDatasetAllocations,
        .{},
    );
}

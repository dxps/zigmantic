//! Parsers and serializers for RDF concrete syntaxes.

const std = @import("std");
const iri_mod = @import("iri.zig");
const rdf = @import("rdf.zig");

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidSyntax,
    InvalidUtf8,
};
pub const SerializeError = std.mem.Allocator.Error || error{
    InvalidBlankNodeLabel,
    UnknownTerm,
};

pub const TurtleOptions = struct {
    /// Initial base IRI supplied by the containing document or retrieval context.
    base_iri: ?[]const u8 = null,
};

/// Implements the RDF 1.1 Turtle grammar and resolves relative IRIs against the
/// document base supplied through `options` or declared in the input.
pub fn parseTurtle(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: TurtleOptions,
) ParseError!rdf.Graph {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var graph = rdf.Graph.init(allocator);
    errdefer graph.deinit();
    var parser = TurtleParser.init(allocator, input, options) catch |err| return mapIriError(err);
    defer parser.deinit();
    var target = StatementTarget{ .graph = &graph };
    try parser.parseInto(&target);
    return graph;
}

/// Implements the RDF 1.1 TriG grammar and resolves relative IRIs against the document
/// base supplied through `options` or declared in the input.
pub fn parseTriG(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: TurtleOptions,
) ParseError!rdf.Dataset {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var dataset = rdf.Dataset.init(allocator);
    errdefer dataset.deinit();
    var parser = TurtleParser.init(allocator, input, options) catch |err| return mapIriError(err);
    defer parser.deinit();
    try parser.parseTriGInto(&dataset);
    return dataset;
}

/// Parses one complete RDF 1.1 N-Triples document into an owned graph.
pub fn parseNTriples(allocator: std.mem.Allocator, input: []const u8) ParseError!rdf.Graph {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var graph = rdf.Graph.init(allocator);
    errdefer graph.deinit();

    var parser = LineParser{ .allocator = allocator, .input = input };
    try parser.parseNTriplesInto(&graph);
    return graph;
}

/// Parses one complete RDF 1.1 N-Quads document into an owned dataset.
pub fn parseNQuads(allocator: std.mem.Allocator, input: []const u8) ParseError!rdf.Dataset {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var dataset = rdf.Dataset.init(allocator);
    errdefer dataset.deinit();

    var parser = LineParser{ .allocator = allocator, .input = input };
    try parser.parseNQuadsInto(&dataset);
    return dataset;
}

/// Serializes a graph using the canonical RDF 1.1 N-Triples layout.
/// Triple order follows graph iteration order; this function does not perform
/// RDF graph canonicalization or blank-node relabeling.
pub fn serializeNTriplesAlloc(
    allocator: std.mem.Allocator,
    graph: *const rdf.Graph,
) SerializeError![]u8 {
    return serializeExpandedGraphAlloc(allocator, graph);
}

/// Serializes a graph as deterministic, expanded RDF 1.1 Turtle.
/// The output deliberately uses the N-Triples-compatible Turtle subset: one triple per
/// line, absolute IRIs, explicit datatypes, and explicit blank-node labels.
pub fn serializeTurtleAlloc(
    allocator: std.mem.Allocator,
    graph: *const rdf.Graph,
) SerializeError![]u8 {
    return serializeExpandedGraphAlloc(allocator, graph);
}

/// Serializes a dataset as deterministic, expanded RDF 1.1 TriG.
/// Default-graph triples use the N-Triples-compatible form. Each named-graph quad uses
/// its own `GRAPH name { ... }` block so dataset iteration order is preserved exactly.
pub fn serializeTriGAlloc(
    allocator: std.mem.Allocator,
    dataset: *const rdf.Dataset,
) SerializeError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (dataset.items()) |quad| {
        switch (quad.graph_name) {
            .default => {},
            .named => |graph_name| {
                try output.appendSlice(allocator, "GRAPH ");
                try appendTerm(allocator, &output, &dataset.terms, graph_name);
                try output.appendSlice(allocator, " { ");
            },
        }
        try appendTerm(allocator, &output, &dataset.terms, quad.subject);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &dataset.terms, quad.predicate);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &dataset.terms, quad.object);
        switch (quad.graph_name) {
            .default => try output.appendSlice(allocator, " .\n"),
            .named => try output.appendSlice(allocator, " . }\n"),
        }
    }
    return output.toOwnedSlice(allocator);
}

fn serializeExpandedGraphAlloc(
    allocator: std.mem.Allocator,
    graph: *const rdf.Graph,
) SerializeError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (graph.items()) |triple| {
        try appendTerm(allocator, &output, &graph.terms, triple.subject);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &graph.terms, triple.predicate);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &graph.terms, triple.object);
        try output.appendSlice(allocator, " .\n");
    }
    return output.toOwnedSlice(allocator);
}

/// Serializes a dataset using the canonical RDF 1.1 N-Quads layout.
/// Quad order follows dataset iteration order; blank nodes are not relabeled.
pub fn serializeNQuadsAlloc(
    allocator: std.mem.Allocator,
    dataset: *const rdf.Dataset,
) SerializeError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (dataset.items()) |quad| {
        try appendTerm(allocator, &output, &dataset.terms, quad.subject);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &dataset.terms, quad.predicate);
        try output.append(allocator, ' ');
        try appendTerm(allocator, &output, &dataset.terms, quad.object);
        switch (quad.graph_name) {
            .default => {},
            .named => |graph_name| {
                try output.append(allocator, ' ');
                try appendTerm(allocator, &output, &dataset.terms, graph_name);
            },
        }
        try output.appendSlice(allocator, " .\n");
    }
    return output.toOwnedSlice(allocator);
}

fn appendTerm(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    pool: *const rdf.TermPool,
    id: rdf.TermId,
) SerializeError!void {
    const term = pool.view(id) orelse return error.UnknownTerm;
    switch (term) {
        .named_node => |iri| try appendIri(allocator, output, iri),
        .blank_node => |identifier| {
            if (!isNTriplesBlankLabel(identifier)) return error.InvalidBlankNodeLabel;
            try output.appendSlice(allocator, "_:");
            try output.appendSlice(allocator, identifier);
        },
        .literal => |literal| {
            try output.append(allocator, '"');
            for (literal.lexical_form) |byte| switch (byte) {
                '"' => try output.appendSlice(allocator, "\\\""),
                '\\' => try output.appendSlice(allocator, "\\\\"),
                '\n' => try output.appendSlice(allocator, "\\n"),
                '\r' => try output.appendSlice(allocator, "\\r"),
                else => try output.append(allocator, byte),
            };
            try output.append(allocator, '"');

            if (literal.language) |language| {
                try output.append(allocator, '@');
                try output.appendSlice(allocator, language);
            } else if (!std.mem.eql(u8, literal.datatype, rdf.xsd_string)) {
                try output.appendSlice(allocator, "^^");
                try appendIri(allocator, output, literal.datatype);
            }
        },
    }
}

fn appendIri(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    iri: []const u8,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '<');
    try output.appendSlice(allocator, iri);
    try output.append(allocator, '>');
}

const TurtleToken = struct {
    tag: Tag,
    lexeme: []const u8,

    const Tag = enum {
        at_base,
        at_prefix,
        base,
        prefix,
        iri_ref,
        prefixed_name,
        blank_node_label,
        string_literal,
        language_tag,
        datatype_marker,
        integer,
        decimal,
        double,
        boolean,
        keyword_a,
        keyword_graph,
        semicolon,
        comma,
        left_bracket,
        right_bracket,
        left_parenthesis,
        right_parenthesis,
        left_brace,
        right_brace,
        dot,
        eof,
    };
};

const TurtleLexer = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *TurtleLexer) ParseError!TurtleToken {
        self.skipIgnored();
        if (self.index == self.input.len) return .{ .tag = .eof, .lexeme = "" };

        const start = self.index;
        switch (self.input[self.index]) {
            '.' => {
                if (self.index + 1 < self.input.len and
                    std.ascii.isDigit(self.input[self.index + 1]))
                {
                    return self.scanWord(start);
                }
                self.index += 1;
                return .{ .tag = .dot, .lexeme = self.input[start..self.index] };
            },
            ';' => {
                self.index += 1;
                return .{ .tag = .semicolon, .lexeme = self.input[start..self.index] };
            },
            ',' => {
                self.index += 1;
                return .{ .tag = .comma, .lexeme = self.input[start..self.index] };
            },
            '[' => {
                self.index += 1;
                return .{ .tag = .left_bracket, .lexeme = self.input[start..self.index] };
            },
            ']' => {
                self.index += 1;
                return .{ .tag = .right_bracket, .lexeme = self.input[start..self.index] };
            },
            '(' => {
                self.index += 1;
                return .{ .tag = .left_parenthesis, .lexeme = self.input[start..self.index] };
            },
            ')' => {
                self.index += 1;
                return .{ .tag = .right_parenthesis, .lexeme = self.input[start..self.index] };
            },
            '{' => {
                self.index += 1;
                return .{ .tag = .left_brace, .lexeme = self.input[start..self.index] };
            },
            '}' => {
                self.index += 1;
                return .{ .tag = .right_brace, .lexeme = self.input[start..self.index] };
            },
            '"', '\'' => return self.scanString(),
            '^' => {
                if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '^') {
                    return error.InvalidSyntax;
                }
                self.index += 2;
                return .{ .tag = .datatype_marker, .lexeme = self.input[start..self.index] };
            },
            '<' => {
                self.index += 1;
                const value_start = self.index;
                while (self.index < self.input.len) : (self.index += 1) {
                    if (self.input[self.index] == '>') {
                        const value = self.input[value_start..self.index];
                        self.index += 1;
                        return .{ .tag = .iri_ref, .lexeme = value };
                    }
                    if (self.input[self.index] == '\n' or self.input[self.index] == '\r') {
                        return error.InvalidSyntax;
                    }
                }
                return error.InvalidSyntax;
            },
            '@' => {
                self.index += 1;
                while (self.index < self.input.len and std.ascii.isAlphabetic(self.input[self.index])) {
                    self.index += 1;
                }
                const directive = self.input[start..self.index];
                if (std.mem.eql(u8, directive, "@base")) return .{ .tag = .at_base, .lexeme = directive };
                if (std.mem.eql(u8, directive, "@prefix")) return .{ .tag = .at_prefix, .lexeme = directive };
                while (self.index < self.input.len and
                    (std.ascii.isAlphanumeric(self.input[self.index]) or self.input[self.index] == '-'))
                {
                    self.index += 1;
                }
                return .{ .tag = .language_tag, .lexeme = self.input[start + 1 .. self.index] };
            },
            else => {},
        }

        return self.scanWord(start);
    }

    fn scanWord(self: *TurtleLexer, start: usize) ParseError!TurtleToken {
        while (self.index < self.input.len and !isTurtleDelimiter(self.input[self.index])) {
            if (self.input[self.index] == '\\') {
                self.index += 1;
                if (self.index >= self.input.len) return error.InvalidSyntax;
            }
            self.index += 1;
        }
        if (self.index == start) return error.InvalidSyntax;
        if (self.input[self.index - 1] == '.' and
            (self.index - start < 2 or self.input[self.index - 2] != '\\'))
        {
            self.index -= 1;
        }
        if (self.index == start) return error.InvalidSyntax;
        const word = self.input[start..self.index];
        if (std.ascii.eqlIgnoreCase(word, "BASE")) return .{ .tag = .base, .lexeme = word };
        if (std.ascii.eqlIgnoreCase(word, "PREFIX")) return .{ .tag = .prefix, .lexeme = word };
        if (std.mem.eql(u8, word, "a")) return .{ .tag = .keyword_a, .lexeme = word };
        if (std.ascii.eqlIgnoreCase(word, "GRAPH")) return .{ .tag = .keyword_graph, .lexeme = word };
        if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) {
            return .{ .tag = .boolean, .lexeme = word };
        }
        if (classifyTurtleNumeric(word)) |tag| return .{ .tag = tag, .lexeme = word };
        if (std.mem.startsWith(u8, word, "_:")) {
            if (std.mem.indexOfScalar(u8, word[2..], ':')) |colon| {
                const end = start + 2 + colon;
                self.index = end;
                return .{ .tag = .blank_node_label, .lexeme = self.input[start + 2 .. end] };
            }
            return .{ .tag = .blank_node_label, .lexeme = word[2..] };
        }
        if (std.mem.indexOfScalar(u8, word, ':') != null) {
            return .{ .tag = .prefixed_name, .lexeme = word };
        }
        return error.InvalidSyntax;
    }

    fn scanString(self: *TurtleLexer) ParseError!TurtleToken {
        const quote = self.input[self.index];
        const long = self.index + 2 < self.input.len and
            self.input[self.index + 1] == quote and self.input[self.index + 2] == quote;
        const delimiter_len: usize = if (long) 3 else 1;
        self.index += delimiter_len;
        const value_start = self.index;

        while (self.index < self.input.len) {
            if (self.input[self.index] == '\\') {
                self.index += 1;
                if (self.index >= self.input.len) return error.InvalidSyntax;
                self.index += 1;
                continue;
            }
            if (!long and (self.input[self.index] == '\n' or self.input[self.index] == '\r')) {
                return error.InvalidSyntax;
            }
            if (self.input[self.index] == quote) {
                if (!long) {
                    const value = self.input[value_start..self.index];
                    self.index += 1;
                    return .{ .tag = .string_literal, .lexeme = value };
                }
                if (self.index + 2 < self.input.len and
                    self.input[self.index + 1] == quote and self.input[self.index + 2] == quote)
                {
                    const value = self.input[value_start..self.index];
                    self.index += 3;
                    return .{ .tag = .string_literal, .lexeme = value };
                }
            }
            self.index += 1;
        }
        return error.InvalidSyntax;
    }

    fn skipIgnored(self: *TurtleLexer) void {
        while (self.index < self.input.len) {
            switch (self.input[self.index]) {
                ' ', '\t', '\n', '\r' => self.index += 1,
                '#' => {
                    while (self.index < self.input.len and
                        self.input[self.index] != '\n' and self.input[self.index] != '\r')
                    {
                        self.index += 1;
                    }
                },
                else => return,
            }
        }
    }
};

fn isTurtleDelimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or switch (byte) {
        '<', '>', '#', ';', ',', '[', ']', '(', ')', '{', '}', '"', '\'', '@', '^' => true,
        else => false,
    };
}

const StatementTarget = union(enum) {
    graph: *rdf.Graph,
    dataset: DatasetTarget,

    const DatasetTarget = struct {
        dataset: *rdf.Dataset,
        graph_name: rdf.GraphName,
    };

    fn terms(self: *StatementTarget) *rdf.TermPool {
        return switch (self.*) {
            .graph => |graph| &graph.terms,
            .dataset => |target| &target.dataset.terms,
        };
    }

    fn add(self: *StatementTarget, triple: rdf.Triple) rdf.Error!void {
        switch (self.*) {
            .graph => |graph| _ = try graph.add(triple),
            .dataset => |target| _ = try target.dataset.add(.{
                .subject = triple.subject,
                .predicate = triple.predicate,
                .object = triple.object,
                .graph_name = target.graph_name,
            }),
        }
    }
};

const TurtleParser = struct {
    allocator: std.mem.Allocator,
    lexer: TurtleLexer,
    arena: std.heap.ArenaAllocator,
    prefixes: std.StringHashMapUnmanaged([]const u8) = .empty,
    labeled_blank_nodes: std.StringHashMapUnmanaged(rdf.TermId) = .empty,
    generated_blank_labels: std.StringHashMapUnmanaged(void) = .empty,
    base_iri: ?[]const u8 = null,
    lookahead: ?TurtleToken = null,
    next_blank_node: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        input: []const u8,
        options: TurtleOptions,
    ) iri_mod.ResolveError!TurtleParser {
        var parser = TurtleParser{
            .allocator = allocator,
            .lexer = .{ .input = input },
            .arena = .init(allocator),
        };
        errdefer parser.deinit();
        if (options.base_iri) |base| {
            if (!iri_mod.isAbsolute(base)) return error.InvalidBase;
            parser.base_iri = try parser.arena.allocator().dupe(u8, base);
        }
        return parser;
    }

    fn deinit(self: *TurtleParser) void {
        self.generated_blank_labels.deinit(self.allocator);
        self.labeled_blank_nodes.deinit(self.allocator);
        self.prefixes.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn parseInto(self: *TurtleParser, target: *StatementTarget) ParseError!void {
        while (true) {
            const first = try self.nextToken();
            switch (first.tag) {
                .eof => return,
                .at_base => try self.parseBaseDirective(true),
                .base => try self.parseBaseDirective(false),
                .at_prefix => try self.parsePrefixDirective(true),
                .prefix => try self.parsePrefixDirective(false),
                .iri_ref, .prefixed_name, .blank_node_label, .left_bracket, .left_parenthesis => try self.parseTriple(target, first, null),
                else => return error.InvalidSyntax,
            }
        }
    }

    fn parseTriGInto(self: *TurtleParser, dataset: *rdf.Dataset) ParseError!void {
        var default_target = StatementTarget{ .dataset = .{
            .dataset = dataset,
            .graph_name = .default,
        } };

        while (true) {
            const first = try self.nextToken();
            switch (first.tag) {
                .eof => return,
                .at_base => try self.parseBaseDirective(true),
                .base => try self.parseBaseDirective(false),
                .at_prefix => try self.parsePrefixDirective(true),
                .prefix => try self.parsePrefixDirective(false),
                .left_brace => try self.parseGraphBlock(dataset, .default),
                .keyword_graph => {
                    const graph_name = try self.parseGraphName(&dataset.terms, try self.nextToken());
                    try self.expect(.left_brace);
                    try self.parseGraphBlock(dataset, .{ .named = graph_name });
                },
                .iri_ref, .prefixed_name, .blank_node_label => {
                    const next = try self.nextToken();
                    if (next.tag == .left_brace) {
                        const graph_name = try self.parseGraphName(&dataset.terms, first);
                        try self.parseGraphBlock(dataset, .{ .named = graph_name });
                    } else {
                        const subject = try self.parseSubject(&default_target, first);
                        try self.parseTripleAfterSubject(&default_target, subject, next, null);
                    }
                },
                .left_bracket => {
                    const property_list = try self.parseBlankNodePropertyList(&default_target);
                    const next = try self.nextToken();
                    if (!property_list.nonempty and next.tag == .left_brace) {
                        try self.parseGraphBlock(dataset, .{ .named = property_list.id });
                    } else {
                        try self.parseTripleAfterSubject(
                            &default_target,
                            .{ .id = property_list.id, .standalone = property_list.nonempty },
                            next,
                            null,
                        );
                    }
                },
                .left_parenthesis => try self.parseTriple(&default_target, first, null),
                else => return error.InvalidSyntax,
            }
        }
    }

    fn parseGraphBlock(
        self: *TurtleParser,
        dataset: *rdf.Dataset,
        graph_name: rdf.GraphName,
    ) ParseError!void {
        var target = StatementTarget{ .dataset = .{
            .dataset = dataset,
            .graph_name = graph_name,
        } };
        while (true) {
            const first = try self.nextToken();
            switch (first.tag) {
                .right_brace => return,
                .eof => return error.InvalidSyntax,
                .iri_ref, .prefixed_name, .blank_node_label, .left_bracket, .left_parenthesis => try self.parseTriple(&target, first, .right_brace),
                else => return error.InvalidSyntax,
            }
        }
    }

    fn parseGraphName(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        token: TurtleToken,
    ) ParseError!rdf.TermId {
        if (token.tag == .blank_node_label) return self.parseBlankNode(pool, token.lexeme);
        if (token.tag == .left_bracket) {
            try self.expect(.right_bracket);
            return self.freshBlankNode(pool);
        }
        return self.parseResource(pool, token);
    }

    fn parseBaseDirective(self: *TurtleParser, requires_dot: bool) ParseError!void {
        const value = try self.nextToken();
        if (value.tag != .iri_ref) return error.InvalidSyntax;
        const decoded = try self.decodeIriRef(value.lexeme);
        defer self.allocator.free(decoded);
        const resolved = try self.resolveIri(decoded);
        defer self.allocator.free(resolved);
        self.base_iri = try self.arena.allocator().dupe(u8, resolved);
        if (requires_dot) try self.expect(.dot);
    }

    fn parsePrefixDirective(self: *TurtleParser, requires_dot: bool) ParseError!void {
        const name = try self.nextToken();
        if (name.tag != .prefixed_name) return error.InvalidSyntax;
        const colon = std.mem.indexOfScalar(u8, name.lexeme, ':') orelse return error.InvalidSyntax;
        if (colon + 1 != name.lexeme.len or !isPrefixLabel(name.lexeme[0..colon])) {
            return error.InvalidSyntax;
        }
        const value = try self.nextToken();
        if (value.tag != .iri_ref) return error.InvalidSyntax;
        const decoded = try self.decodeIriRef(value.lexeme);
        defer self.allocator.free(decoded);
        const resolved = try self.resolveIri(decoded);
        defer self.allocator.free(resolved);

        const owned_prefix = try self.arena.allocator().dupe(u8, name.lexeme[0..colon]);
        const owned_namespace = try self.arena.allocator().dupe(u8, resolved);
        try self.prefixes.put(self.allocator, owned_prefix, owned_namespace);
        if (requires_dot) try self.expect(.dot);
    }

    fn parseTriple(
        self: *TurtleParser,
        target: *StatementTarget,
        subject_token: TurtleToken,
        alternate_terminator: ?TurtleToken.Tag,
    ) ParseError!void {
        const subject = try self.parseSubject(target, subject_token);
        const predicate_token = try self.nextToken();
        try self.parseTripleAfterSubject(target, subject, predicate_token, alternate_terminator);
    }

    fn parseTripleAfterSubject(
        self: *TurtleParser,
        target: *StatementTarget,
        subject: ParsedSubject,
        predicate_token: TurtleToken,
        alternate_terminator: ?TurtleToken.Tag,
    ) ParseError!void {
        if (predicate_token.tag == .dot) {
            if (subject.standalone) return;
            return error.InvalidSyntax;
        }
        if (alternate_terminator == predicate_token.tag) {
            if (!subject.standalone) return error.InvalidSyntax;
            self.lookahead = predicate_token;
            return;
        }
        try self.parsePredicateObjectList(
            target,
            subject.id,
            predicate_token,
            .dot,
            alternate_terminator,
        );
    }

    fn parsePredicateObjectList(
        self: *TurtleParser,
        target: *StatementTarget,
        subject: rdf.TermId,
        first_predicate: TurtleToken,
        terminator: TurtleToken.Tag,
        alternate_terminator: ?TurtleToken.Tag,
    ) ParseError!void {
        var predicate_token = first_predicate;
        while (true) {
            const predicate = if (predicate_token.tag == .keyword_a)
                target.terms().internNamedNode(rdf.rdf_namespace ++ "type") catch |err| return mapTermError(err)
            else
                try self.parseResource(target.terms(), predicate_token);

            var separator: TurtleToken = undefined;
            while (true) {
                const object = try self.parseObject(target, try self.nextToken());
                try self.addTriple(target, subject, predicate, object);
                separator = try self.nextToken();
                if (separator.tag != .comma) break;
            }

            if (separator.tag == terminator) return;
            if (alternate_terminator == separator.tag) {
                self.lookahead = separator;
                return;
            }
            if (separator.tag != .semicolon) return error.InvalidSyntax;

            while (separator.tag == .semicolon) separator = try self.nextToken();
            if (separator.tag == terminator) return;
            if (alternate_terminator == separator.tag) {
                self.lookahead = separator;
                return;
            }
            predicate_token = separator;
        }
    }

    fn addTriple(
        self: *TurtleParser,
        target: *StatementTarget,
        subject: rdf.TermId,
        predicate: rdf.TermId,
        object: rdf.TermId,
    ) ParseError!void {
        _ = self;
        target.add(.{
            .subject = subject,
            .predicate = predicate,
            .object = object,
        }) catch |err| return mapTermError(err);
    }

    const ParsedSubject = struct {
        id: rdf.TermId,
        standalone: bool = false,
    };

    const ParsedPropertyList = struct {
        id: rdf.TermId,
        nonempty: bool,
    };

    fn parseSubject(
        self: *TurtleParser,
        target: *StatementTarget,
        token: TurtleToken,
    ) ParseError!ParsedSubject {
        if (token.tag == .blank_node_label) return .{
            .id = try self.parseBlankNode(target.terms(), token.lexeme),
        };
        if (token.tag == .left_bracket) {
            const property_list = try self.parseBlankNodePropertyList(target);
            return .{ .id = property_list.id, .standalone = property_list.nonempty };
        }
        if (token.tag == .left_parenthesis) return .{ .id = try self.parseCollection(target) };
        return .{ .id = try self.parseResource(target.terms(), token) };
    }

    fn parseObject(
        self: *TurtleParser,
        target: *StatementTarget,
        token: TurtleToken,
    ) ParseError!rdf.TermId {
        return switch (token.tag) {
            .blank_node_label => self.parseBlankNode(target.terms(), token.lexeme),
            .left_bracket => (try self.parseBlankNodePropertyList(target)).id,
            .left_parenthesis => self.parseCollection(target),
            .string_literal => self.parseStringLiteral(target.terms(), token.lexeme),
            .integer => self.parseTypedLiteral(target.terms(), token.lexeme, rdf.xsd_namespace ++ "integer"),
            .decimal => self.parseTypedLiteral(target.terms(), token.lexeme, rdf.xsd_namespace ++ "decimal"),
            .double => self.parseTypedLiteral(target.terms(), token.lexeme, rdf.xsd_namespace ++ "double"),
            .boolean => self.parseTypedLiteral(target.terms(), token.lexeme, rdf.xsd_namespace ++ "boolean"),
            else => self.parseResource(target.terms(), token),
        };
    }

    fn parseBlankNode(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        label: []const u8,
    ) ParseError!rdf.TermId {
        if (!isNTriplesBlankLabel(label)) return error.InvalidSyntax;
        if (self.labeled_blank_nodes.get(label)) |id| return id;

        const id = if (self.generated_blank_labels.contains(label))
            try self.freshBlankNode(pool)
        else
            pool.internBlankNode(label) catch |err| return mapTermError(err);
        try self.labeled_blank_nodes.put(self.allocator, label, id);
        return id;
    }

    fn parseBlankNodePropertyList(
        self: *TurtleParser,
        target: *StatementTarget,
    ) ParseError!ParsedPropertyList {
        const blank_node = try self.freshBlankNode(target.terms());
        const first = try self.nextToken();
        if (first.tag == .right_bracket) return .{ .id = blank_node, .nonempty = false };
        try self.parsePredicateObjectList(target, blank_node, first, .right_bracket, null);
        return .{ .id = blank_node, .nonempty = true };
    }

    fn parseCollection(self: *TurtleParser, target: *StatementTarget) ParseError!rdf.TermId {
        const nil = target.terms().internNamedNode(rdf.rdf_namespace ++ "nil") catch |err|
            return mapTermError(err);
        var item_token = try self.nextToken();
        if (item_token.tag == .right_parenthesis) return nil;

        const first_predicate = target.terms().internNamedNode(rdf.rdf_namespace ++ "first") catch |err|
            return mapTermError(err);
        const rest_predicate = target.terms().internNamedNode(rdf.rdf_namespace ++ "rest") catch |err|
            return mapTermError(err);
        const head = try self.freshBlankNode(target.terms());
        var current = head;

        while (true) {
            const item = try self.parseObject(target, item_token);
            const next = try self.nextToken();
            try self.addTriple(target, current, first_predicate, item);

            if (next.tag == .right_parenthesis) {
                try self.addTriple(target, current, rest_predicate, nil);
                return head;
            }

            const tail = try self.freshBlankNode(target.terms());
            try self.addTriple(target, current, rest_predicate, tail);
            current = tail;
            item_token = next;
        }
    }

    fn freshBlankNode(self: *TurtleParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        while (true) {
            var buffer: [64]u8 = undefined;
            const label = std.fmt.bufPrint(
                &buffer,
                "zigmantic-anon-{d}",
                .{self.next_blank_node},
            ) catch unreachable;
            self.next_blank_node += 1;

            const term_count = pool.count();
            const id = pool.internBlankNode(label) catch |err| return mapTermError(err);
            if (pool.count() == term_count) continue;

            const stored_label = pool.view(id).?.blank_node;
            try self.generated_blank_labels.put(self.allocator, stored_label, {});
            return id;
        }
    }

    fn parseStringLiteral(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        raw: []const u8,
    ) ParseError!rdf.TermId {
        const lexical_form = try self.decodeString(raw);
        defer self.allocator.free(lexical_form);

        const suffix = try self.nextToken();
        switch (suffix.tag) {
            .language_tag => return pool.internLanguageLiteral(lexical_form, suffix.lexeme) catch |err|
                return mapTermError(err),
            .at_base, .at_prefix => return pool.internLanguageLiteral(lexical_form, suffix.lexeme[1..]) catch |err|
                return mapTermError(err),
            .datatype_marker => {
                const datatype_token = try self.nextToken();
                const datatype = try self.resolveResource(datatype_token);
                defer self.allocator.free(datatype);
                return pool.internTypedLiteral(lexical_form, datatype) catch |err|
                    return mapTermError(err);
            },
            else => {
                self.lookahead = suffix;
                return pool.internSimpleLiteral(lexical_form) catch |err| return mapTermError(err);
            },
        }
    }

    fn parseTypedLiteral(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        lexical_form: []const u8,
        datatype: []const u8,
    ) ParseError!rdf.TermId {
        _ = self;
        return pool.internTypedLiteral(lexical_form, datatype) catch |err| return mapTermError(err);
    }

    fn parseResource(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        token: TurtleToken,
    ) ParseError!rdf.TermId {
        switch (token.tag) {
            .iri_ref => {
                const resolved = try self.resolveResource(token);
                defer self.allocator.free(resolved);
                return pool.internNamedNode(resolved) catch |err| return mapTermError(err);
            },
            .prefixed_name => {
                const resolved = try self.resolveResource(token);
                defer self.allocator.free(resolved);
                return pool.internNamedNode(resolved) catch |err| return mapTermError(err);
            },
            else => return error.InvalidSyntax,
        }
    }

    fn resolveResource(self: *TurtleParser, token: TurtleToken) ParseError![]u8 {
        return switch (token.tag) {
            .iri_ref => blk: {
                const decoded = try self.decodeIriRef(token.lexeme);
                defer self.allocator.free(decoded);
                break :blk try self.resolveIri(decoded);
            },
            .prefixed_name => self.expandPrefixedName(token.lexeme),
            else => error.InvalidSyntax,
        };
    }

    fn decodeString(self: *TurtleParser, raw: []const u8) ParseError![]u8 {
        var decoded: std.ArrayList(u8) = .empty;
        errdefer decoded.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] != '\\') {
                try decoded.append(self.allocator, raw[index]);
                index += 1;
                continue;
            }
            index += 1;
            if (index >= raw.len) return error.InvalidSyntax;
            const escaped = raw[index];
            switch (escaped) {
                't' => try decoded.append(self.allocator, '\t'),
                'b' => try decoded.append(self.allocator, 0x08),
                'n' => try decoded.append(self.allocator, '\n'),
                'r' => try decoded.append(self.allocator, '\r'),
                'f' => try decoded.append(self.allocator, 0x0c),
                '"' => try decoded.append(self.allocator, '"'),
                '\'' => try decoded.append(self.allocator, '\''),
                '\\' => try decoded.append(self.allocator, '\\'),
                'u', 'U' => {
                    try decodeUnicodeEscape(self.allocator, &decoded, raw, &index);
                    continue;
                },
                else => return error.InvalidSyntax,
            }
            index += 1;
        }
        return decoded.toOwnedSlice(self.allocator);
    }

    fn decodeIriRef(self: *TurtleParser, raw: []const u8) ParseError![]u8 {
        var decoded: std.ArrayList(u8) = .empty;
        errdefer decoded.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            const byte = raw[index];
            if (byte <= 0x20 or byte == 0x7f) return error.InvalidSyntax;
            switch (byte) {
                '<', '>', '"', '{', '}', '|', '^', '`' => return error.InvalidSyntax,
                '\\' => {
                    index += 1;
                    try decodeUnicodeEscape(self.allocator, &decoded, raw, &index);
                },
                else => {
                    try decoded.append(self.allocator, byte);
                    index += 1;
                },
            }
        }
        return decoded.toOwnedSlice(self.allocator);
    }

    fn resolveIri(self: *TurtleParser, value: []const u8) ParseError![]u8 {
        if (iri_mod.isAbsolute(value)) return self.allocator.dupe(u8, value);
        const base = self.base_iri orelse return error.InvalidSyntax;
        return iri_mod.resolveAlloc(self.allocator, base, value) catch |err| return mapIriError(err);
    }

    fn expandPrefixedName(self: *TurtleParser, value: []const u8) ParseError![]u8 {
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidSyntax;
        if (!isPrefixLabel(value[0..colon])) return error.InvalidSyntax;
        const namespace = self.prefixes.get(value[0..colon]) orelse return error.InvalidSyntax;
        const local = value[colon + 1 ..];

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, namespace);
        try appendDecodedPnLocal(self.allocator, &expanded, local);
        return expanded.toOwnedSlice(self.allocator);
    }

    fn expect(self: *TurtleParser, expected: TurtleToken.Tag) ParseError!void {
        if ((try self.nextToken()).tag != expected) return error.InvalidSyntax;
    }

    fn nextToken(self: *TurtleParser) ParseError!TurtleToken {
        if (self.lookahead) |token| {
            self.lookahead = null;
            return token;
        }
        return self.lexer.next();
    }
};

fn classifyTurtleNumeric(value: []const u8) ?TurtleToken.Tag {
    if (value.len == 0) return null;
    var index: usize = 0;
    if (value[index] == '+' or value[index] == '-') {
        index += 1;
        if (index == value.len) return null;
    }

    const integer_start = index;
    while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
    const integer_digits = index - integer_start;

    var has_dot = false;
    var fraction_digits: usize = 0;
    if (index < value.len and value[index] == '.') {
        has_dot = true;
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
        fraction_digits = index - fraction_start;
    }

    var has_exponent = false;
    if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
        has_exponent = true;
        index += 1;
        if (index < value.len and (value[index] == '+' or value[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
        if (index == exponent_start) return null;
    }
    if (index != value.len) return null;

    if (has_exponent and (integer_digits > 0 or fraction_digits > 0)) return .double;
    if (has_dot and fraction_digits > 0) return .decimal;
    if (!has_dot and integer_digits > 0) return .integer;
    return null;
}

fn isPrefixLabel(value: []const u8) bool {
    if (value.len == 0) return true;
    var index: usize = 0;
    const first = nextCodepoint(value, &index) orelse return false;
    if (!isPnCharsBase(first)) return false;
    var may_end = true;
    while (index < value.len) {
        const codepoint = nextCodepoint(value, &index) orelse return false;
        if (codepoint == '.') {
            may_end = false;
        } else if (isPnChars(codepoint)) {
            may_end = true;
        } else {
            return false;
        }
    }
    return may_end;
}

fn appendDecodedPnLocal(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) ParseError!void {
    var index: usize = 0;
    var unit_index: usize = 0;
    var may_end = value.len == 0;
    while (index < value.len) : (unit_index += 1) {
        if (value[index] == '\\') {
            index += 1;
            if (index >= value.len or !isPnLocalEscaped(value[index])) return error.InvalidSyntax;
            try output.append(allocator, value[index]);
            index += 1;
            may_end = true;
            continue;
        }
        if (value[index] == '%') {
            if (value.len - index < 3 or
                !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2]))
            {
                return error.InvalidSyntax;
            }
            try output.appendSlice(allocator, value[index .. index + 3]);
            index += 3;
            may_end = true;
            continue;
        }

        const start = index;
        const codepoint = nextCodepoint(value, &index) orelse return error.InvalidSyntax;
        const allowed = if (unit_index == 0)
            isPnCharsU(codepoint) or codepoint == ':' or (codepoint >= '0' and codepoint <= '9')
        else
            isPnChars(codepoint) or codepoint == '.' or codepoint == ':';
        if (!allowed) return error.InvalidSyntax;
        try output.appendSlice(allocator, value[start..index]);
        may_end = codepoint != '.';
    }
    if (!may_end) return error.InvalidSyntax;
}

fn nextCodepoint(value: []const u8, index: *usize) ?u21 {
    if (index.* >= value.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(value[index.*]) catch return null;
    if (value.len - index.* < length) return null;
    const codepoint = std.unicode.utf8Decode(value[index.* .. index.* + length]) catch return null;
    index.* += length;
    return codepoint;
}

fn isPnCharsU(codepoint: u21) bool {
    return isPnCharsBase(codepoint) or codepoint == '_';
}

fn isPnChars(codepoint: u21) bool {
    return isPnCharsU(codepoint) or codepoint == '-' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0x00b7 or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x203f and codepoint <= 0x2040);
}

fn isPnLocalEscaped(byte: u8) bool {
    return switch (byte) {
        '_', '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '@', '%' => true,
        else => false,
    };
}

fn decodeUnicodeEscape(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    input: []const u8,
    index: *usize,
) ParseError!void {
    if (index.* >= input.len) return error.InvalidSyntax;
    const digits: usize = switch (input[index.*]) {
        'u' => 4,
        'U' => 8,
        else => return error.InvalidSyntax,
    };
    index.* += 1;
    if (input.len - index.* < digits) return error.InvalidSyntax;
    var codepoint: u32 = 0;
    for (input[index.* .. index.* + digits]) |digit| {
        codepoint = codepoint * 16 + (std.fmt.charToDigit(digit, 16) catch return error.InvalidSyntax);
    }
    index.* += digits;
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) {
        return error.InvalidSyntax;
    }
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return error.InvalidSyntax;
    try output.appendSlice(allocator, encoded[0..length]);
}

fn mapIriError(err: iri_mod.ResolveError) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.InvalidBase, error.InvalidReference => error.InvalidSyntax,
    };
}

const LineParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn parseNTriplesInto(self: *LineParser, graph: *rdf.Graph) ParseError!void {
        try self.skipEmptyLinesAndComments();
        while (!self.atEnd()) {
            const subject = try self.parseSubject(&graph.terms);
            self.skipHorizontalWhitespace();
            const predicate = try self.parseIri(&graph.terms);
            self.skipHorizontalWhitespace();
            const object = try self.parseObject(&graph.terms);
            self.skipHorizontalWhitespace();
            try self.finishStatement();

            _ = graph.add(.{
                .subject = subject,
                .predicate = predicate,
                .object = object,
            }) catch |err| return mapTermError(err);
            try self.skipEmptyLinesAndComments();
        }
    }

    fn parseNQuadsInto(self: *LineParser, dataset: *rdf.Dataset) ParseError!void {
        try self.skipEmptyLinesAndComments();
        while (!self.atEnd()) {
            const subject = try self.parseSubject(&dataset.terms);
            self.skipHorizontalWhitespace();
            const predicate = try self.parseIri(&dataset.terms);
            self.skipHorizontalWhitespace();
            const object = try self.parseObject(&dataset.terms);
            self.skipHorizontalWhitespace();

            const graph_name: rdf.GraphName = if (self.peek() == '.')
                .default
            else
                .{ .named = try self.parseSubject(&dataset.terms) };
            self.skipHorizontalWhitespace();
            try self.finishStatement();

            _ = dataset.add(.{
                .subject = subject,
                .predicate = predicate,
                .object = object,
                .graph_name = graph_name,
            }) catch |err| return mapTermError(err);
            try self.skipEmptyLinesAndComments();
        }
    }

    fn finishStatement(self: *LineParser) ParseError!void {
        try self.expect('.');
        self.skipHorizontalWhitespace();
        if (self.peek() == '#') self.skipComment();
        try self.consumeLineEndOrEof();
    }

    fn parseSubject(self: *LineParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        return switch (self.peek() orelse return error.InvalidSyntax) {
            '<' => self.parseIri(pool),
            '_' => self.parseBlankNode(pool),
            else => error.InvalidSyntax,
        };
    }

    fn parseObject(self: *LineParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        return switch (self.peek() orelse return error.InvalidSyntax) {
            '<' => self.parseIri(pool),
            '_' => self.parseBlankNode(pool),
            '"' => self.parseLiteral(pool),
            else => error.InvalidSyntax,
        };
    }

    fn parseIri(self: *LineParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.allocator);
        try self.parseIriValue(&value);
        return pool.internNamedNode(value.items) catch |err| return mapTermError(err);
    }

    fn parseIriValue(self: *LineParser, value: *std.ArrayList(u8)) ParseError!void {
        try self.expect('<');
        while (self.peek()) |byte| {
            switch (byte) {
                '>' => {
                    self.index += 1;
                    return;
                },
                '\\' => {
                    self.index += 1;
                    try self.parseUnicodeEscape(value);
                },
                0x00...0x20, 0x7f, '<', '"', '{', '}', '|', '^', '`' => return error.InvalidSyntax,
                else => {
                    try value.append(self.allocator, byte);
                    self.index += 1;
                },
            }
        }
        return error.InvalidSyntax;
    }

    fn parseBlankNode(self: *LineParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        try self.expect('_');
        try self.expect(':');
        const start = self.index;
        const first_length = blankCharacterLength(self.input, self.index, true) orelse
            return error.InvalidSyntax;
        self.index += first_length;

        while (!self.atEnd()) {
            if (self.input[self.index] == '.') {
                self.index += 1;
                continue;
            }
            const length = blankCharacterLength(self.input, self.index, false) orelse break;
            self.index += length;
        }
        if (self.input[self.index - 1] == '.') self.index -= 1;
        if (self.index == start or self.input[self.index - 1] == '.') return error.InvalidSyntax;
        return pool.internBlankNode(self.input[start..self.index]) catch |err| return mapTermError(err);
    }

    fn parseLiteral(self: *LineParser, pool: *rdf.TermPool) ParseError!rdf.TermId {
        var lexical_form: std.ArrayList(u8) = .empty;
        defer lexical_form.deinit(self.allocator);

        try self.expect('"');
        while (self.peek()) |byte| {
            switch (byte) {
                '"' => {
                    self.index += 1;
                    break;
                },
                '\\' => {
                    self.index += 1;
                    try self.parseStringEscape(&lexical_form);
                },
                '\n', '\r' => return error.InvalidSyntax,
                else => {
                    try lexical_form.append(self.allocator, byte);
                    self.index += 1;
                },
            }
        } else return error.InvalidSyntax;

        if (self.peek() == '@') {
            self.index += 1;
            const language = try self.parseLanguageTag();
            return pool.internLanguageLiteral(lexical_form.items, language) catch |err| return mapTermError(err);
        }
        if (self.peek() == '^') {
            self.index += 1;
            try self.expect('^');
            var datatype: std.ArrayList(u8) = .empty;
            defer datatype.deinit(self.allocator);
            try self.parseIriValue(&datatype);
            return pool.internTypedLiteral(lexical_form.items, datatype.items) catch |err| return mapTermError(err);
        }
        return pool.internSimpleLiteral(lexical_form.items) catch |err| return mapTermError(err);
    }

    fn parseLanguageTag(self: *LineParser) ParseError![]const u8 {
        const start = self.index;
        while (self.peek()) |byte| {
            if (!std.ascii.isAlphabetic(byte)) break;
            self.index += 1;
        }
        if (self.index == start) return error.InvalidSyntax;

        while (self.peek() == '-') {
            self.index += 1;
            const part_start = self.index;
            while (self.peek()) |byte| {
                if (!std.ascii.isAlphanumeric(byte)) break;
                self.index += 1;
            }
            if (self.index == part_start) return error.InvalidSyntax;
        }
        return self.input[start..self.index];
    }

    fn parseStringEscape(self: *LineParser, output: *std.ArrayList(u8)) ParseError!void {
        const escaped = self.peek() orelse return error.InvalidSyntax;
        self.index += 1;
        const decoded: u8 = switch (escaped) {
            't' => '\t',
            'b' => 0x08,
            'n' => '\n',
            'r' => '\r',
            'f' => 0x0c,
            '"' => '"',
            '\'' => '\'',
            '\\' => '\\',
            'u', 'U' => {
                self.index -= 1;
                return self.parseUnicodeEscape(output);
            },
            else => return error.InvalidSyntax,
        };
        try output.append(self.allocator, decoded);
    }

    fn parseUnicodeEscape(self: *LineParser, output: *std.ArrayList(u8)) ParseError!void {
        const marker = self.peek() orelse return error.InvalidSyntax;
        self.index += 1;
        const digits: usize = switch (marker) {
            'u' => 4,
            'U' => 8,
            else => return error.InvalidSyntax,
        };
        if (self.input.len - self.index < digits) return error.InvalidSyntax;

        var codepoint: u32 = 0;
        for (self.input[self.index .. self.index + digits]) |digit| {
            codepoint = codepoint * 16 + (std.fmt.charToDigit(digit, 16) catch return error.InvalidSyntax);
        }
        self.index += digits;
        if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) {
            return error.InvalidSyntax;
        }

        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return error.InvalidSyntax;
        try output.appendSlice(self.allocator, encoded[0..length]);
    }

    fn skipEmptyLinesAndComments(self: *LineParser) ParseError!void {
        while (true) {
            self.skipHorizontalWhitespace();
            if (self.peek() == '#') self.skipComment();
            if (try self.consumeLineEnd()) continue;
            return;
        }
    }

    fn skipHorizontalWhitespace(self: *LineParser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t') return;
            self.index += 1;
        }
    }

    fn skipComment(self: *LineParser) void {
        while (self.peek()) |byte| {
            if (byte == '\n' or byte == '\r') return;
            self.index += 1;
        }
    }

    fn consumeLineEndOrEof(self: *LineParser) ParseError!void {
        if (self.atEnd()) return;
        if (!(try self.consumeLineEnd())) return error.InvalidSyntax;
    }

    fn consumeLineEnd(self: *LineParser) ParseError!bool {
        if (self.peek() == '\n') {
            self.index += 1;
            return true;
        }
        if (self.peek() == '\r') {
            self.index += 1;
            if (self.peek() != '\n') return error.InvalidSyntax;
            self.index += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *LineParser, expected: u8) ParseError!void {
        if (self.peek() != expected) return error.InvalidSyntax;
        self.index += 1;
    }

    fn peek(self: *const LineParser) ?u8 {
        if (self.atEnd()) return null;
        return self.input[self.index];
    }

    fn atEnd(self: *const LineParser) bool {
        return self.index >= self.input.len;
    }
};

fn isNTriplesBlankLabel(identifier: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(identifier) or identifier.len == 0) return false;
    var index: usize = blankCharacterLength(identifier, 0, true) orelse return false;
    while (index < identifier.len) {
        if (identifier[index] == '.') {
            if (index + 1 == identifier.len) return false;
            index += 1;
            continue;
        }
        const length = blankCharacterLength(identifier, index, false) orelse return false;
        index += length;
    }
    return true;
}

fn blankCharacterLength(input: []const u8, index: usize, first: bool) ?usize {
    if (index >= input.len) return null;
    const length: usize = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
    if (input.len - index < length) return null;
    const codepoint = std.unicode.utf8Decode(input[index .. index + length]) catch return null;

    if (isPnCharsBase(codepoint) or codepoint == '_') return length;
    if (codepoint >= '0' and codepoint <= '9') return length;
    if (!first and (codepoint == '-' or codepoint == 0x00b7 or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x203f and codepoint <= 0x2040))) return length;
    return null;
}

fn isPnCharsBase(codepoint: u21) bool {
    return (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0x00c0 and codepoint <= 0x00d6) or
        (codepoint >= 0x00d8 and codepoint <= 0x00f6) or
        (codepoint >= 0x00f8 and codepoint <= 0x02ff) or
        (codepoint >= 0x0370 and codepoint <= 0x037d) or
        (codepoint >= 0x037f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

fn mapTermError(err: rdf.Error) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSyntax,
    };
}

test "N-Triples parses empty input and comments" {
    var graph = try parseNTriples(std.testing.allocator, "  # comment\r\n\n\t# another");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 0), graph.len());
}

test "N-Triples parses RDF term forms and escapes" {
    const input =
        "<https://example.com/s> <https://example.com/name> \"Bun\\u0103\\nziua\"@RO .\n" ++
        "_:subject <https://example.com/value> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n" ++
        "<https://example.com/escaped\\u002Firi> <https://example.com/link> _:subject . # trailing\n";
    var graph = try parseNTriples(std.testing.allocator, input);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 3), graph.len());
    const language_literal = graph.terms.view(graph.items()[0].object).?.literal;
    try std.testing.expectEqualStrings("Bună\nziua", language_literal.lexical_form);
    try std.testing.expectEqualStrings("ro", language_literal.language.?);
    try std.testing.expectEqualStrings(
        "https://example.com/escaped/iri",
        graph.terms.view(graph.items()[2].subject).?.named_node,
    );
}

test "N-Triples graph retains set semantics" {
    const line = "<https://example.com/s> <https://example.com/p> \"o\" .\n";
    var graph = try parseNTriples(std.testing.allocator, line ++ line);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.len());
}

test "N-Triples enforces Unicode blank-node label boundaries" {
    var graph = try parseNTriples(
        std.testing.allocator,
        "_:é·clair <https://example.com/p> _:nodé .\n",
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.len());

    const invalid = [_][]const u8{
        "_:-bad <https://example.com/p> \"o\" .\n",
        "_:a <https://example.com/p> _:trailing..\n",
        "_:a <https://example.com/p> _:\u{200e}bad .\n",
    };
    for (invalid) |input| {
        try std.testing.expectError(error.InvalidSyntax, parseNTriples(std.testing.allocator, input));
    }
}

test "N-Triples serializer emits canonical syntax" {
    var graph = rdf.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const subject = try graph.terms.internBlankNode("subject.1");
    const predicate = try graph.terms.internNamedNode("https://example.com/name");
    const language_literal = try graph.terms.internLanguageLiteral("Bună\n\"ziua\"\\", "RO");
    const typed_literal = try graph.terms.internTypedLiteral("42", rdf.xsd_namespace ++ "integer");
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = language_literal });
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = typed_literal });

    const output = try serializeNTriplesAlloc(std.testing.allocator, &graph);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "_:subject.1 <https://example.com/name> \"Bună\\n\\\"ziua\\\"\\\\\"@ro .\n" ++
            "_:subject.1 <https://example.com/name> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n",
        output,
    );
}

test "N-Triples parse and serialize round trip is stable" {
    const input =
        "<https://example.com/s> <https://example.com/p> \"line\\nvalue\" .\n" ++
        "_:node <https://example.com/p> <https://example.com/o> .\n";
    var first = try parseNTriples(std.testing.allocator, input);
    defer first.deinit();
    const serialized = try serializeNTriplesAlloc(std.testing.allocator, &first);
    defer std.testing.allocator.free(serialized);

    var second = try parseNTriples(std.testing.allocator, serialized);
    defer second.deinit();
    const serialized_again = try serializeNTriplesAlloc(std.testing.allocator, &second);
    defer std.testing.allocator.free(serialized_again);
    try std.testing.expectEqualStrings(serialized, serialized_again);
}

test "N-Triples serializer rejects unrepresentable blank-node identifiers" {
    var graph = rdf.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const subject = try graph.terms.internBlankNode("not?an-ntriples-label");
    const predicate = try graph.terms.internNamedNode("https://example.com/p");
    const object = try graph.terms.internSimpleLiteral("object");
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = object });
    try std.testing.expectError(
        error.InvalidBlankNodeLabel,
        serializeNTriplesAlloc(std.testing.allocator, &graph),
    );
}

test "N-Triples rejects malformed documents" {
    const invalid = [_][]const u8{
        "<relative> <https://example.com/p> <https://example.com/o> .\n",
        "<https://example.com/s> garbage <https://example.com/o> .\n",
        "<https://example.com/s> _:predicate \"o\" .\n",
        "<https://example.com/s> <https://example.com/p> 'o' .\n",
        "<https://example.com/s> <https://example.com/p> \"bad\\x\" .\n",
        "<https://example.com/s> <https://example.com/p> \"bad\nvalue\" .\n",
        "<https://example.com/s> <https://example.com/p> \"o\"\n",
        "_:bad. <https://example.com/p> \"o\" .\n",
        "# comment\rnext",
    };
    for (invalid) |input| {
        try std.testing.expectError(error.InvalidSyntax, parseNTriples(std.testing.allocator, input));
    }

    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, parseNTriples(std.testing.allocator, &invalid_utf8));
}

fn exerciseNTriplesAllocations(allocator: std.mem.Allocator) !void {
    var graph = try parseNTriples(
        allocator,
        "<https://example.com/s> <https://example.com/p> \"Bun\\u0103\"@ro .\n",
    );
    defer graph.deinit();

    const serialized = try serializeNTriplesAlloc(allocator, &graph);
    defer allocator.free(serialized);
}

test "N-Triples I/O handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNTriplesAllocations,
        .{},
    );
}

test "N-Quads parses default, IRI-named, and blank-node-named graphs" {
    const input =
        "<https://example.com/s> <https://example.com/p> \"default\" .\n" ++
        "_:s <https://example.com/p> <https://example.com/o> <https://example.com/graph> .\n" ++
        "<https://example.com/s> <https://example.com/p> \"named\"@EN _:graph .\n";
    var dataset = try parseNQuads(std.testing.allocator, input);
    defer dataset.deinit();

    try std.testing.expectEqual(@as(usize, 3), dataset.len());
    try std.testing.expectEqual(rdf.GraphName.default, dataset.items()[0].graph_name);
    const iri_graph = dataset.terms.view(dataset.items()[1].graph_name.named).?.named_node;
    try std.testing.expectEqualStrings("https://example.com/graph", iri_graph);
    const blank_graph = dataset.terms.view(dataset.items()[2].graph_name.named).?.blank_node;
    try std.testing.expectEqualStrings("graph", blank_graph);
}

test "N-Quads rejects invalid graph labels and extra terms" {
    const invalid = [_][]const u8{
        "<https://example.com/s> <https://example.com/p> \"o\" \"literal graph\" .\n",
        "<https://example.com/s> <https://example.com/p> \"o\" <relative> .\n",
        "<https://example.com/s> <https://example.com/p> \"o\" <https://example.com/g> <https://example.com/extra> .\n",
    };
    for (invalid) |input| {
        try std.testing.expectError(error.InvalidSyntax, parseNQuads(std.testing.allocator, input));
    }
}

test "N-Quads serialization is canonical and round trips stably" {
    const input =
        "<https://example.com/s><https://example.com/p>\"line\\nvalue\".\n" ++
        "_:subject <https://example.com/p> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> _:graph .\n";
    var first = try parseNQuads(std.testing.allocator, input);
    defer first.deinit();
    const serialized = try serializeNQuadsAlloc(std.testing.allocator, &first);
    defer std.testing.allocator.free(serialized);

    try std.testing.expectEqualStrings(
        "<https://example.com/s> <https://example.com/p> \"line\\nvalue\" .\n" ++
            "_:subject <https://example.com/p> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> _:graph .\n",
        serialized,
    );

    var second = try parseNQuads(std.testing.allocator, serialized);
    defer second.deinit();
    const serialized_again = try serializeNQuadsAlloc(std.testing.allocator, &second);
    defer std.testing.allocator.free(serialized_again);
    try std.testing.expectEqualStrings(serialized, serialized_again);
}

fn exerciseNQuadsAllocations(allocator: std.mem.Allocator) !void {
    var dataset = try parseNQuads(
        allocator,
        "_:s <https://example.com/p> \"Bun\\u0103\"@ro <https://example.com/g> .\n",
    );
    defer dataset.deinit();

    const serialized = try serializeNQuadsAlloc(allocator, &dataset);
    defer allocator.free(serialized);
}

test "N-Quads I/O handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNQuadsAllocations,
        .{},
    );
}

test "Turtle parses directives, relative IRIs, prefixed names, and a" {
    const input =
        "@base <https://example.com/doc/> .\n" ++
        "@prefix ex: <vocab/> .\n" ++
        "<subject> a ex:Thing .\n" ++
        "ex:subject ex:related <../object> .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.len());
    const first = graph.items()[0];
    try std.testing.expectEqualStrings(
        "https://example.com/doc/subject",
        graph.terms.view(first.subject).?.named_node,
    );
    try std.testing.expectEqualStrings(
        rdf.rdf_namespace ++ "type",
        graph.terms.view(first.predicate).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/doc/vocab/Thing",
        graph.terms.view(first.object).?.named_node,
    );

    const second = graph.items()[1];
    try std.testing.expectEqualStrings(
        "https://example.com/doc/vocab/subject",
        graph.terms.view(second.subject).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/object",
        graph.terms.view(second.object).?.named_node,
    );
}

test "Turtle supports SPARQL directives and an external base IRI" {
    const input =
        "PrEfIx : <vocabulary/>\n" ++
        "BaSe <nested/>\n" ++
        ":subject :predicate <object> .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{
        .base_iri = "https://example.com/root/",
    });
    defer graph.deinit();

    const triple = graph.items()[0];
    try std.testing.expectEqualStrings(
        "https://example.com/root/vocabulary/subject",
        graph.terms.view(triple.subject).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/root/nested/object",
        graph.terms.view(triple.object).?.named_node,
    );
}

test "Turtle parses string forms, language tags, and explicit datatypes" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:short \"line\\nvalue\" .\n" ++
        "ex:s ex:single 'single\\'quote' .\n" ++
        "ex:s ex:long \"\"\"long\nvalue\"\"\" .\n" ++
        "ex:s ex:longSingle '''long\nsingle''' .\n" ++
        "ex:s ex:language \"Salut\"@RO-Latn .\n" ++
        "ex:s ex:keywordLanguage \"value\"@prefix .\n" ++
        "ex:s ex:typed \"answer\"^^ex:custom .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 7), graph.len());
    const expected_lexical_forms = [_][]const u8{
        "line\nvalue",
        "single'quote",
        "long\nvalue",
        "long\nsingle",
        "Salut",
        "value",
        "answer",
    };
    for (graph.items(), expected_lexical_forms) |triple, expected| {
        try std.testing.expectEqualStrings(
            expected,
            graph.terms.view(triple.object).?.literal.lexical_form,
        );
    }

    const language = graph.terms.view(graph.items()[4].object).?.literal;
    try std.testing.expectEqualStrings("ro-latn", language.language.?);
    try std.testing.expectEqualStrings(rdf.rdf_lang_string, language.datatype);

    const keyword_language = graph.terms.view(graph.items()[5].object).?.literal;
    try std.testing.expectEqualStrings("prefix", keyword_language.language.?);

    const typed = graph.terms.view(graph.items()[6].object).?.literal;
    try std.testing.expectEqualStrings("https://example.com/custom", typed.datatype);
    try std.testing.expect(typed.language == null);
}

test "Turtle assigns native literal datatypes" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:integer +42 .\n" ++
        "ex:s ex:decimal .5 .\n" ++
        "ex:s ex:double 6.02e23 .\n" ++
        "ex:s ex:boolean false .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    const expected = [_]struct { lexical: []const u8, datatype: []const u8 }{
        .{ .lexical = "+42", .datatype = rdf.xsd_namespace ++ "integer" },
        .{ .lexical = ".5", .datatype = rdf.xsd_namespace ++ "decimal" },
        .{ .lexical = "6.02e23", .datatype = rdf.xsd_namespace ++ "double" },
        .{ .lexical = "false", .datatype = rdf.xsd_namespace ++ "boolean" },
    };
    for (graph.items(), expected) |triple, value| {
        const literal = graph.terms.view(triple.object).?.literal;
        try std.testing.expectEqualStrings(value.lexical, literal.lexical_form);
        try std.testing.expectEqualStrings(value.datatype, literal.datatype);
    }
}

test "Turtle parses labeled blank-node subjects and objects" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "_:subject ex:knows _:object .\n" ++
        "_:object ex:name \"Object\" .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqualStrings(
        "subject",
        graph.terms.view(graph.items()[0].subject).?.blank_node,
    );
    try std.testing.expectEqualStrings(
        "object",
        graph.terms.view(graph.items()[0].object).?.blank_node,
    );
    try std.testing.expectEqual(
        graph.items()[0].object,
        graph.items()[1].subject,
    );
}

test "Turtle separates a blank-node label from an adjacent prefixed predicate" {
    var graph = try parseTurtle(
        std.testing.allocator,
        "@prefix : <https://example.com/> . _:subject:predicate :object .",
        .{},
    );
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.len());
    try std.testing.expectEqualStrings(
        "subject",
        graph.terms.view(graph.items()[0].subject).?.blank_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/predicate",
        graph.terms.view(graph.items()[0].predicate).?.named_node,
    );
}

test "Turtle expands predicate and object lists" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:p ex:first, \"second\", [] ;\n" ++
        "     ex:number 1, 2 ;\n" ++
        "     a ex:Thing ;; .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 6), graph.len());
    const subject = graph.items()[0].subject;
    for (graph.items()) |triple| try std.testing.expectEqual(subject, triple.subject);

    try std.testing.expectEqualStrings(
        "https://example.com/first",
        graph.terms.view(graph.items()[0].object).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "second",
        graph.terms.view(graph.items()[1].object).?.literal.lexical_form,
    );
    _ = graph.terms.view(graph.items()[2].object).?.blank_node;
    try std.testing.expectEqualStrings(
        rdf.rdf_namespace ++ "type",
        graph.terms.view(graph.items()[5].predicate).?.named_node,
    );
}

test "Turtle creates distinct collision-safe anonymous blank nodes" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "[] ex:p ex:first .\n" ++
        "_:zigmantic-anon-0 ex:p ex:labeled .\n" ++
        "_:zigmantic-anon-0 ex:q [] .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    const first_anonymous = graph.items()[0].subject;
    const labeled = graph.items()[1].subject;
    const repeated_labeled = graph.items()[2].subject;
    const second_anonymous = graph.items()[2].object;
    try std.testing.expect(first_anonymous != labeled);
    try std.testing.expectEqual(labeled, repeated_labeled);
    try std.testing.expect(second_anonymous != first_anonymous);
    try std.testing.expect(second_anonymous != labeled);
}

test "Turtle expands nested blank-node property lists" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "[ ex:name \"Alice\" ;\n" ++
        "  ex:knows [ ex:name \"Bob\" ; ex:age 42 ]\n" ++
        "] ex:role ex:Person .\n" ++
        "ex:root ex:child [ ex:name \"Carol\" ] .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 7), graph.len());
    const alice = graph.items()[0].subject;
    const bob = graph.items()[1].subject;
    try std.testing.expect(alice != bob);
    try std.testing.expectEqual(bob, graph.items()[2].subject);
    try std.testing.expectEqual(alice, graph.items()[3].subject);
    try std.testing.expectEqual(bob, graph.items()[3].object);
    try std.testing.expectEqual(alice, graph.items()[4].subject);

    const carol = graph.items()[5].subject;
    try std.testing.expectEqual(carol, graph.items()[6].object);
    try std.testing.expectEqualStrings(
        "Carol",
        graph.terms.view(graph.items()[5].object).?.literal.lexical_form,
    );
}

test "Turtle expands RDF collections and nested structures" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:list (ex:first \"second\" [ ex:name \"third\" ] ()) .\n" ++
        "(ex:left (ex:nested)) ex:kind ex:ListSubject .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 17), graph.len());
    const head = graph.items()[0].subject;
    try std.testing.expectEqualStrings(
        rdf.rdf_namespace ++ "first",
        graph.terms.view(graph.items()[0].predicate).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/first",
        graph.terms.view(graph.items()[0].object).?.named_node,
    );

    const second_cell = graph.items()[1].object;
    try std.testing.expectEqual(second_cell, graph.items()[2].subject);
    try std.testing.expectEqualStrings(
        "second",
        graph.terms.view(graph.items()[2].object).?.literal.lexical_form,
    );

    const property_node = graph.items()[4].subject;
    try std.testing.expectEqual(property_node, graph.items()[5].object);
    try std.testing.expectEqualStrings(
        "third",
        graph.terms.view(graph.items()[4].object).?.literal.lexical_form,
    );

    const nil = graph.terms.view(graph.items()[7].object).?.named_node;
    try std.testing.expectEqualStrings(rdf.rdf_namespace ++ "nil", nil);
    try std.testing.expectEqualStrings(
        rdf.rdf_namespace ++ "nil",
        graph.terms.view(graph.items()[8].object).?.named_node,
    );
    try std.testing.expectEqual(head, graph.items()[9].object);

    const nested_head = graph.items()[12].subject;
    try std.testing.expectEqual(nested_head, graph.items()[14].object);
    try std.testing.expectEqual(graph.items()[10].subject, graph.items()[16].subject);
}

test "Turtle represents an empty collection as rdf:nil" {
    const input =
        "@prefix ex: <https://example.com/> . () ex:sameAs () .";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.len());
    try std.testing.expectEqual(graph.items()[0].subject, graph.items()[0].object);
    try std.testing.expectEqualStrings(
        rdf.rdf_namespace ++ "nil",
        graph.terms.view(graph.items()[0].subject).?.named_node,
    );
}

test "Turtle serializer emits deterministic expanded syntax" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:p \"line\\nvalue\" .\n" ++
        "_:node ex:p \"Salut\"@RO .\n";
    var graph = try parseTurtle(std.testing.allocator, input, .{});
    defer graph.deinit();
    const serialized = try serializeTurtleAlloc(std.testing.allocator, &graph);
    defer std.testing.allocator.free(serialized);

    try std.testing.expectEqualStrings(
        "<https://example.com/s> <https://example.com/p> \"line\\nvalue\" .\n" ++
            "_:node <https://example.com/p> \"Salut\"@ro .\n",
        serialized,
    );
}

test "Turtle expanded serialization round trips stably" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "[ ex:name \"Alice\" ; ex:items (ex:first [ ex:name \"second\" ] ()) ] " ++
        "a ex:Container .\n";
    var first = try parseTurtle(std.testing.allocator, input, .{});
    defer first.deinit();
    const serialized = try serializeTurtleAlloc(std.testing.allocator, &first);
    defer std.testing.allocator.free(serialized);

    var second = try parseTurtle(std.testing.allocator, serialized, .{});
    defer second.deinit();
    const serialized_again = try serializeTurtleAlloc(std.testing.allocator, &second);
    defer std.testing.allocator.free(serialized_again);

    try std.testing.expectEqual(first.len(), second.len());
    try std.testing.expectEqualStrings(serialized, serialized_again);
}

fn exerciseTurtleSerializationAllocations(allocator: std.mem.Allocator) !void {
    var graph = try parseTurtle(
        allocator,
        "@prefix ex: <https://example.com/> . _:s ex:p \"Bună\\nziua\"@ro .",
        .{},
    );
    defer graph.deinit();
    const serialized = try serializeTurtleAlloc(allocator, &graph);
    defer allocator.free(serialized);
}

test "Turtle serialization handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTurtleSerializationAllocations,
        .{},
    );
}

test "TriG parses default and named graph blocks" {
    const input =
        "@base <https://example.com/> .\n" ++
        "@prefix ex: <vocab/> .\n" ++
        "<outside> ex:p \"default statement\" .\n" ++
        "{ <inside> ex:p \"default block\" . }\n" ++
        "ex:graph { ex:s ex:p \"named\" . }\n" ++
        "GrApH <other> { _:shared ex:p [ ex:q ex:o ] . }\n" ++
        "_:blankGraph { ex:s ex:p _:shared . }\n";
    var dataset = try parseTriG(std.testing.allocator, input, .{});
    defer dataset.deinit();

    try std.testing.expectEqual(@as(usize, 6), dataset.len());
    try std.testing.expectEqual(rdf.GraphName.default, dataset.items()[0].graph_name);
    try std.testing.expectEqual(rdf.GraphName.default, dataset.items()[1].graph_name);

    try std.testing.expectEqualStrings(
        "https://example.com/vocab/graph",
        dataset.terms.view(dataset.items()[2].graph_name.named).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/other",
        dataset.terms.view(dataset.items()[3].graph_name.named).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "blankGraph",
        dataset.terms.view(dataset.items()[5].graph_name.named).?.blank_node,
    );

    const shared = dataset.items()[4].subject;
    try std.testing.expectEqual(shared, dataset.items()[5].object);
}

test "TriG permits an omitted dot before a graph block closing brace" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "{ ex:s ex:p ex:o }\n" ++
        "GRAPH ex:first { ex:s ex:p ex:o ; }\n" ++
        "ex:second { [ ex:p ex:o ] }\n" ++
        "ex:third { ex:s ex:p [ ex:q ex:o ], ex:other }";
    var dataset = try parseTriG(std.testing.allocator, input, .{});
    defer dataset.deinit();

    try std.testing.expectEqual(@as(usize, 6), dataset.len());
    try std.testing.expectEqual(rdf.GraphName.default, dataset.items()[0].graph_name);
    try std.testing.expectEqualStrings(
        "https://example.com/first",
        dataset.terms.view(dataset.items()[1].graph_name.named).?.named_node,
    );
}

test "TriG supports anonymous blank-node graph names" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "[] { ex:s ex:p ex:o }\n" ++
        "GRAPH [] { ex:s ex:p ex:other }";
    var dataset = try parseTriG(std.testing.allocator, input, .{});
    defer dataset.deinit();

    try std.testing.expectEqual(@as(usize, 2), dataset.len());
    const first_name = dataset.items()[0].graph_name.named;
    const second_name = dataset.items()[1].graph_name.named;
    try std.testing.expect(dataset.terms.view(first_name).? == .blank_node);
    try std.testing.expect(dataset.terms.view(second_name).? == .blank_node);
    try std.testing.expect(first_name != second_name);
}

test "TriG expanded serialization has deterministic byte output" {
    var dataset = rdf.Dataset.init(std.testing.allocator);
    defer dataset.deinit();

    const subject = try dataset.terms.internNamedNode("https://example.com/s");
    const predicate = try dataset.terms.internNamedNode("https://example.com/p");
    const object = try dataset.terms.internLanguageLiteral("Bună\nziua", "RO");
    const graph = try dataset.terms.internBlankNode("graph");
    _ = try dataset.addDefault(.{ .subject = subject, .predicate = predicate, .object = object });
    _ = try dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph },
    });

    const output = try serializeTriGAlloc(std.testing.allocator, &dataset);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "<https://example.com/s> <https://example.com/p> \"Bună\\nziua\"@ro .\n" ++
            "GRAPH _:graph { <https://example.com/s> <https://example.com/p> \"Bună\\nziua\"@ro . }\n",
        output,
    );
}

test "TriG expanded serialization round trips stably" {
    const input =
        "@prefix ex: <https://example.com/> .\n" ++
        "ex:s ex:p [ ex:name \"default\" ] .\n" ++
        "GRAPH _:graph { _:shared ex:p (ex:first ex:second) }\n" ++
        "ex:named { ex:s ex:p _:shared }";
    var first = try parseTriG(std.testing.allocator, input, .{});
    defer first.deinit();
    const serialized = try serializeTriGAlloc(std.testing.allocator, &first);
    defer std.testing.allocator.free(serialized);

    var second = try parseTriG(std.testing.allocator, serialized, .{});
    defer second.deinit();
    const serialized_again = try serializeTriGAlloc(std.testing.allocator, &second);
    defer std.testing.allocator.free(serialized_again);

    try std.testing.expectEqual(first.len(), second.len());
    try std.testing.expectEqualStrings(serialized, serialized_again);
}

fn exerciseTriGSerializationAllocations(allocator: std.mem.Allocator) !void {
    var dataset = try parseTriG(
        allocator,
        "@prefix ex: <https://example.com/> . " ++
            "ex:s ex:p \"default\" . " ++
            "GRAPH _:graph { _:s ex:p \"Bună\\nziua\"@ro }",
        .{},
    );
    defer dataset.deinit();
    const serialized = try serializeTriGAlloc(allocator, &dataset);
    defer allocator.free(serialized);
}

test "TriG serialization handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTriGSerializationAllocations,
        .{},
    );
}

test "Turtle still requires a dot after a top-level triple" {
    try std.testing.expectError(
        error.InvalidSyntax,
        parseTurtle(
            std.testing.allocator,
            "<https://example.com/s> <https://example.com/p> <https://example.com/o>",
            .{},
        ),
    );
}

test "TriG rejects malformed graph blocks" {
    const invalid = [_][]const u8{
        "@prefix ex: <https://example.com/> . ex:g { ex:s ex:p ex:o .",
        "@prefix ex: <https://example.com/> . GRAPH { ex:s ex:p ex:o . }",
        "@prefix ex: <https://example.com/> . \"literal\" { ex:s ex:p ex:o . }",
        "@prefix ex: <https://example.com/> . ex:g { ex:h { ex:s ex:p ex:o . } }",
        "{ @base <https://example.com/> . }",
        "{ BASE <https://example.com/> }",
        "{ @prefix ex: <https://example.com/> . }",
        "{ PREFIX ex: <https://example.com/> }",
        "}",
    };
    for (invalid) |input| {
        try std.testing.expectError(
            error.InvalidSyntax,
            parseTriG(std.testing.allocator, input, .{}),
        );
    }
}

fn exerciseTriGAllocations(allocator: std.mem.Allocator) !void {
    var dataset = try parseTriG(
        allocator,
        "@prefix ex: <https://example.com/> . " ++
            "ex:g { ex:s ex:name \"Alice\" . } " ++
            "{ ex:s ex:p \"default\" . }",
        .{},
    );
    defer dataset.deinit();
}

test "TriG foundation handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTriGAllocations,
        .{},
    );
}

test "Turtle rejects invalid directives and unresolved names" {
    const invalid = [_][]const u8{
        "<relative> <https://example.com/p> <https://example.com/o> .",
        "unknown:s <https://example.com/p> <https://example.com/o> .",
        "@prefix bad <https://example.com/> .",
        "@BASE <https://example.com/> .",
        "@base <https://example.com/>",
        "@prefix ex: <https://example.com/> . ex:s ex:p \"unterminated .",
        "@prefix ex: <https://example.com/> . ex:s ex:p \"bad\\q\" .",
        "@prefix ex: <https://example.com/> . ex:s ex:p \"value\"@ .",
        "@prefix ex: <https://example.com/> . ex:s ex:p \"value\"^^_:datatype .",
        "@prefix ex: <https://example.com/> . ex:s ex:p _:bad/label .",
        "@prefix ex: <https://example.com/> . \"literal\" ex:p ex:o .",
        "@prefix ex: <https://example.com/> . ex:s ex:p ex:o, .",
        "@prefix ex: <https://example.com/> . ex:s ex:p ex:o; , ex:q .",
        "@prefix ex: <https://example.com/> . [ ; ] ex:q ex:r .",
        "@prefix ex: <https://example.com/> . ex:s ex:p [ ex:q ] .",
        "@prefix ex: <https://example.com/> . ex:s ex:p [ ex:q ex:o .",
        "@prefix ex: <https://example.com/> . ex:s ex:p [ .",
        "@prefix ex: <https://example.com/> . ex:s ex:p ( .",
        "@prefix ex: <https://example.com/> . ex:s ex:p (ex:a ] .",
        "@prefix ex: <https://example.com/> . ex:s ex:p (ex:a, ex:b) .",
        "@prefix ex: <https://example.com/> . ex:s ex:p (ex:a",
        "@prefix ex: <https://example.com/> . ) ex:p ex:o .",
    };
    for (invalid) |input| {
        try std.testing.expectError(
            error.InvalidSyntax,
            parseTurtle(std.testing.allocator, input, .{}),
        );
    }
}

fn exerciseTurtleAllocations(allocator: std.mem.Allocator) !void {
    var graph = try parseTurtle(
        allocator,
        "@base <https://example.com/> . @prefix ex: <vocab/> . " ++
            "[ ex:name \"Bună\\nziua\"@ro ; ex:knows [ ex:name \"Salut\" ] ] " ++
            "a ex:Thing ; ex:items (ex:first [ ex:name \"nested\" ] ()) .",
        .{},
    );
    defer graph.deinit();
}

test "Turtle foundation handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTurtleAllocations,
        .{},
    );
}

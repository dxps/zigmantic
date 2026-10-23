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

/// Parses the currently implemented RDF 1.1 Turtle subset into an owned graph.
/// Directives, IRI references, prefixed names, `a`, and simple resource triples
/// are supported. Other Turtle productions are added incrementally.
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
    try parser.parseInto(&graph);
    return graph;
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
        keyword_a,
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
                self.index += 1;
                return .{ .tag = .dot, .lexeme = self.input[start..self.index] };
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
                return error.InvalidSyntax;
            },
            else => {},
        }

        while (self.index < self.input.len and !isTurtleDelimiter(self.input[self.index])) {
            self.index += 1;
        }
        if (self.index == start) return error.InvalidSyntax;
        if (self.input[self.index - 1] == '.') self.index -= 1;
        if (self.index == start) return error.InvalidSyntax;
        const word = self.input[start..self.index];
        if (std.ascii.eqlIgnoreCase(word, "BASE")) return .{ .tag = .base, .lexeme = word };
        if (std.ascii.eqlIgnoreCase(word, "PREFIX")) return .{ .tag = .prefix, .lexeme = word };
        if (std.mem.eql(u8, word, "a")) return .{ .tag = .keyword_a, .lexeme = word };
        if (std.mem.indexOfScalar(u8, word, ':') != null) {
            return .{ .tag = .prefixed_name, .lexeme = word };
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
        '<', '>', '#', ';', ',', '[', ']', '(', ')', '"', '\'' => true,
        else => false,
    };
}

const TurtleParser = struct {
    allocator: std.mem.Allocator,
    lexer: TurtleLexer,
    arena: std.heap.ArenaAllocator,
    prefixes: std.StringHashMapUnmanaged([]const u8) = .empty,
    base_iri: ?[]const u8 = null,

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
        self.prefixes.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn parseInto(self: *TurtleParser, graph: *rdf.Graph) ParseError!void {
        while (true) {
            const first = try self.lexer.next();
            switch (first.tag) {
                .eof => return,
                .at_base => try self.parseBaseDirective(true),
                .base => try self.parseBaseDirective(false),
                .at_prefix => try self.parsePrefixDirective(true),
                .prefix => try self.parsePrefixDirective(false),
                .iri_ref, .prefixed_name => try self.parseTriple(graph, first),
                else => return error.InvalidSyntax,
            }
        }
    }

    fn parseBaseDirective(self: *TurtleParser, requires_dot: bool) ParseError!void {
        const value = try self.lexer.next();
        if (value.tag != .iri_ref) return error.InvalidSyntax;
        const decoded = try self.decodeIriRef(value.lexeme);
        defer self.allocator.free(decoded);
        const resolved = try self.resolveIri(decoded);
        defer self.allocator.free(resolved);
        self.base_iri = try self.arena.allocator().dupe(u8, resolved);
        if (requires_dot) try self.expect(.dot);
    }

    fn parsePrefixDirective(self: *TurtleParser, requires_dot: bool) ParseError!void {
        const name = try self.lexer.next();
        if (name.tag != .prefixed_name) return error.InvalidSyntax;
        const colon = std.mem.indexOfScalar(u8, name.lexeme, ':') orelse return error.InvalidSyntax;
        if (colon + 1 != name.lexeme.len or !isPrefixLabel(name.lexeme[0..colon])) {
            return error.InvalidSyntax;
        }
        const value = try self.lexer.next();
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
        graph: *rdf.Graph,
        subject_token: TurtleToken,
    ) ParseError!void {
        const subject = try self.parseResource(&graph.terms, subject_token);
        const predicate_token = try self.lexer.next();
        const predicate = if (predicate_token.tag == .keyword_a)
            graph.terms.internNamedNode(rdf.rdf_namespace ++ "type") catch |err| return mapTermError(err)
        else
            try self.parseResource(&graph.terms, predicate_token);
        const object = try self.parseResource(&graph.terms, try self.lexer.next());
        try self.expect(.dot);
        _ = graph.add(.{
            .subject = subject,
            .predicate = predicate,
            .object = object,
        }) catch |err| return mapTermError(err);
    }

    fn parseResource(
        self: *TurtleParser,
        pool: *rdf.TermPool,
        token: TurtleToken,
    ) ParseError!rdf.TermId {
        switch (token.tag) {
            .iri_ref => {
                const decoded = try self.decodeIriRef(token.lexeme);
                defer self.allocator.free(decoded);
                const resolved = try self.resolveIri(decoded);
                defer self.allocator.free(resolved);
                return pool.internNamedNode(resolved) catch |err| return mapTermError(err);
            },
            .prefixed_name => {
                const expanded = try self.expandPrefixedName(token.lexeme);
                defer self.allocator.free(expanded);
                return pool.internNamedNode(expanded) catch |err| return mapTermError(err);
            },
            else => return error.InvalidSyntax,
        }
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
        const namespace = self.prefixes.get(value[0..colon]) orelse return error.InvalidSyntax;
        const local = value[colon + 1 ..];
        if (local.len > 0 and (local[0] == '-' or local[local.len - 1] == '.')) {
            return error.InvalidSyntax;
        }

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, namespace);
        var index: usize = 0;
        while (index < local.len) {
            if (local[index] == '\\') {
                index += 1;
                if (index >= local.len or !isPnLocalEscaped(local[index])) return error.InvalidSyntax;
            }
            try expanded.append(self.allocator, local[index]);
            index += 1;
        }
        return expanded.toOwnedSlice(self.allocator);
    }

    fn expect(self: *TurtleParser, expected: TurtleToken.Tag) ParseError!void {
        if ((try self.lexer.next()).tag != expected) return error.InvalidSyntax;
    }
};

fn isPrefixLabel(value: []const u8) bool {
    if (value.len == 0) return true;
    if (!(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    if (value[value.len - 1] == '.') return false;
    for (value[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.')) return false;
    }
    return true;
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

test "Turtle rejects invalid directives and unresolved names" {
    const invalid = [_][]const u8{
        "<relative> <https://example.com/p> <https://example.com/o> .",
        "unknown:s <https://example.com/p> <https://example.com/o> .",
        "@prefix bad <https://example.com/> .",
        "@BASE <https://example.com/> .",
        "@base <https://example.com/>",
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
        "@base <https://example.com/> . @prefix ex: <vocab/> . ex:s a ex:Thing .",
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

//! SPARQL 1.1 query syntax and algebra foundations.

const std = @import("std");
const iri_mod = @import("iri.zig");

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    InvalidSyntax,
};

pub const TokenTag = enum {
    base,
    prefix,
    select,
    distinct,
    reduced,
    where,
    variable,
    iri_reference,
    prefixed_name,
    left_brace,
    right_brace,
    dot,
    star,
    identifier,
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
    offset: usize,
};

/// Allocation-free tokenizer over a borrowed UTF-8 query string.
pub const Tokenizer = struct {
    input: []const u8,
    index: usize = 0,

    pub fn init(input: []const u8) ParseError!Tokenizer {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) ParseError!Token {
        self.skipIgnored();
        if (self.index == self.input.len) {
            return .{ .tag = .eof, .lexeme = "", .offset = self.index };
        }

        const offset = self.index;
        return switch (self.input[self.index]) {
            '{' => self.single(.left_brace),
            '}' => self.single(.right_brace),
            '.' => self.single(.dot),
            '*' => self.single(.star),
            '?', '$' => self.variable(),
            '<' => self.iriReference(),
            else => self.word(offset),
        };
    }

    fn single(self: *Tokenizer, tag: TokenTag) Token {
        const offset = self.index;
        self.index += 1;
        return .{ .tag = tag, .lexeme = self.input[offset..self.index], .offset = offset };
    }

    fn variable(self: *Tokenizer) ParseError!Token {
        const offset = self.index;
        self.index += 1;
        const name_start = self.index;
        while (self.index < self.input.len and !isDelimiter(self.input[self.index])) {
            self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
        }
        const name = self.input[name_start..self.index];
        if (!isVariableName(name)) return error.InvalidSyntax;
        return .{ .tag = .variable, .lexeme = name, .offset = offset };
    }

    fn iriReference(self: *Tokenizer) ParseError!Token {
        const offset = self.index;
        self.index += 1;
        const value_start = self.index;
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (byte == '>') {
                const value = self.input[value_start..self.index];
                self.index += 1;
                return .{ .tag = .iri_reference, .lexeme = value, .offset = offset };
            }
            if (byte <= 0x20 or byte == '<' or byte == '"' or byte == '{' or byte == '}' or
                byte == '|' or byte == '^' or byte == '`' or byte == '\\')
            {
                return error.InvalidSyntax;
            }
            self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
        }
        return error.InvalidSyntax;
    }

    fn word(self: *Tokenizer, offset: usize) ParseError!Token {
        while (self.index < self.input.len and !isWordDelimiter(self.input[self.index])) {
            if (self.input[self.index] == '\\') {
                self.index += 1;
                if (self.index == self.input.len) return error.InvalidSyntax;
            }
            self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
        }
        if (self.index == offset) return error.InvalidSyntax;
        if (self.input[self.index - 1] == '.' and
            (self.index - offset < 2 or self.input[self.index - 2] != '\\'))
        {
            self.index -= 1;
        }
        if (self.index == offset) return error.InvalidSyntax;
        const lexeme = self.input[offset..self.index];
        const tag: TokenTag = if (std.ascii.eqlIgnoreCase(lexeme, "BASE"))
            .base
        else if (std.ascii.eqlIgnoreCase(lexeme, "PREFIX"))
            .prefix
        else if (std.ascii.eqlIgnoreCase(lexeme, "SELECT"))
            .select
        else if (std.ascii.eqlIgnoreCase(lexeme, "DISTINCT"))
            .distinct
        else if (std.ascii.eqlIgnoreCase(lexeme, "REDUCED"))
            .reduced
        else if (std.ascii.eqlIgnoreCase(lexeme, "WHERE"))
            .where
        else if (isPrefixedName(lexeme))
            .prefixed_name
        else
            .identifier;
        return .{ .tag = tag, .lexeme = lexeme, .offset = offset };
    }

    fn skipIgnored(self: *Tokenizer) void {
        while (self.index < self.input.len) {
            if (isWhitespace(self.input[self.index])) {
                self.index += 1;
                continue;
            }
            if (self.input[self.index] == '#') {
                while (self.index < self.input.len and
                    self.input[self.index] != '\n' and self.input[self.index] != '\r')
                {
                    self.index += 1;
                }
                continue;
            }
            return;
        }
    }
};

pub const Modifier = enum {
    none,
    distinct,
    reduced,
};

pub const PatternTerm = union(enum) {
    variable: []const u8,
    iri: []const u8,
};

pub const TriplePattern = struct {
    subject: PatternTerm,
    predicate: PatternTerm,
    object: PatternTerm,
};

pub const Projection = union(enum) {
    all,
    variables: []const []const u8,
};

pub const Prefix = struct {
    name: []const u8,
    namespace: []const u8,
};

/// Allocator-owned syntax tree for the implemented `SELECT` query slice.
pub const Query = struct {
    allocator: std.mem.Allocator,
    base_iri: ?[]const u8 = null,
    modifier: Modifier,
    select_all: bool,
    prefixes: std.ArrayList(Prefix) = .empty,
    projection_variables: std.ArrayList([]const u8) = .empty,
    where_patterns: std.ArrayList(TriplePattern) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Query {
        return .{
            .allocator = allocator,
            .modifier = .none,
            .select_all = false,
        };
    }

    pub fn deinit(self: *Query) void {
        for (self.owned_strings.items) |value| self.allocator.free(value);
        self.owned_strings.deinit(self.allocator);
        self.prefixes.deinit(self.allocator);
        self.projection_variables.deinit(self.allocator);
        self.where_patterns.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn projection(self: *const Query) Projection {
        return if (self.select_all)
            .all
        else
            .{ .variables = self.projection_variables.items };
    }

    pub fn patterns(self: *const Query) []const TriplePattern {
        return self.where_patterns.items;
    }

    pub fn prefixDeclarations(self: *const Query) []const Prefix {
        return self.prefixes.items;
    }

    /// Produces an allocation-free algebra view borrowing this query's storage.
    pub fn lower(self: *const Query) Algebra {
        return .{ .project = .{
            .projection = self.projection(),
            .input = .{ .bgp = .{ .triples = self.patterns() } },
        } };
    }

    fn own(self: *Query, value: []const u8) std.mem.Allocator.Error![]const u8 {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }
};

pub const BasicGraphPattern = struct {
    triples: []const TriplePattern,
};

pub const Project = struct {
    projection: Projection,
    input: AlgebraInput,
};

pub const AlgebraInput = union(enum) {
    bgp: BasicGraphPattern,
};

/// Borrowed SPARQL algebra view. It remains valid while its source `Query` is alive
/// and structurally unchanged.
pub const Algebra = union(enum) {
    project: Project,
};

/// Parses the initial SPARQL 1.1 query slice: `SELECT`, optional
/// `DISTINCT`/`REDUCED`, variable or wildcard projection, and an optional-`WHERE`
/// basic graph pattern made from variables and IRI references.
pub fn parseQuery(allocator: std.mem.Allocator, input: []const u8) ParseError!Query {
    var parser = Parser{
        .allocator = allocator,
        .tokenizer = try Tokenizer.init(input),
        .query = Query.init(allocator),
    };
    errdefer parser.query.deinit();
    try parser.parse();
    return parser.query;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    query: Query,
    lookahead: ?Token = null,

    fn parse(self: *Parser) ParseError!void {
        try self.parsePrologue();
        try self.expect(.select);
        const modifier = try self.peek();
        if (modifier.tag == .distinct or modifier.tag == .reduced) {
            _ = try self.take();
            self.query.modifier = if (modifier.tag == .distinct) .distinct else .reduced;
        }

        const projection = try self.peek();
        if (projection.tag == .star) {
            _ = try self.take();
            self.query.select_all = true;
        } else {
            while ((try self.peek()).tag == .variable) {
                const variable = try self.take();
                try self.query.projection_variables.append(
                    self.allocator,
                    try self.query.own(variable.lexeme),
                );
            }
            if (self.query.projection_variables.items.len == 0) return error.InvalidSyntax;
        }

        if ((try self.peek()).tag == .where) _ = try self.take();
        try self.expect(.left_brace);
        try self.parseBasicGraphPattern();
        try self.expect(.right_brace);
        try self.expect(.eof);
    }

    fn parsePrologue(self: *Parser) ParseError!void {
        while (true) {
            switch ((try self.peek()).tag) {
                .base => {
                    _ = try self.take();
                    const value = try self.take();
                    if (value.tag != .iri_reference) return error.InvalidSyntax;
                    self.query.base_iri = try self.resolveIri(value.lexeme);
                },
                .prefix => {
                    _ = try self.take();
                    const name = try self.take();
                    if (name.tag != .prefixed_name) return error.InvalidSyntax;
                    const colon = std.mem.indexOfScalar(u8, name.lexeme, ':') orelse
                        return error.InvalidSyntax;
                    if (colon + 1 != name.lexeme.len) return error.InvalidSyntax;
                    const value = try self.take();
                    if (value.tag != .iri_reference) return error.InvalidSyntax;
                    try self.query.prefixes.append(self.allocator, .{
                        .name = try self.query.own(name.lexeme[0..colon]),
                        .namespace = try self.resolveIri(value.lexeme),
                    });
                },
                else => return,
            }
        }
    }

    fn parseBasicGraphPattern(self: *Parser) ParseError!void {
        if ((try self.peek()).tag == .right_brace) return;
        while (true) {
            try self.query.where_patterns.append(self.allocator, .{
                .subject = try self.parseTerm(),
                .predicate = try self.parseTerm(),
                .object = try self.parseTerm(),
            });
            const separator = try self.peek();
            if (separator.tag == .right_brace) return;
            if (separator.tag != .dot) return error.InvalidSyntax;
            _ = try self.take();
            if ((try self.peek()).tag == .right_brace) return;
        }
    }

    fn parseTerm(self: *Parser) ParseError!PatternTerm {
        const token = try self.take();
        return switch (token.tag) {
            .variable => .{ .variable = try self.query.own(token.lexeme) },
            .iri_reference => .{ .iri = try self.resolveIri(token.lexeme) },
            .prefixed_name => .{ .iri = try self.expandPrefixedName(token.lexeme) },
            else => error.InvalidSyntax,
        };
    }

    fn resolveIri(self: *Parser, value: []const u8) ParseError![]const u8 {
        if (iri_mod.isAbsolute(value) or self.query.base_iri == null) {
            return self.query.own(value);
        }
        const resolved = iri_mod.resolveAlloc(
            self.allocator,
            self.query.base_iri.?,
            value,
        ) catch |err| return mapIriError(err);
        errdefer self.allocator.free(resolved);
        try self.query.owned_strings.append(self.allocator, resolved);
        return resolved;
    }

    fn expandPrefixedName(self: *Parser, value: []const u8) ParseError![]const u8 {
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidSyntax;
        const namespace = self.findPrefix(value[0..colon]) orelse return error.InvalidSyntax;

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, namespace);
        try appendDecodedPnLocal(self.allocator, &expanded, value[colon + 1 ..]);
        const owned = try expanded.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        try self.query.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn findPrefix(self: *const Parser, name: []const u8) ?[]const u8 {
        var index = self.query.prefixes.items.len;
        while (index > 0) {
            index -= 1;
            const prefix = self.query.prefixes.items[index];
            if (std.mem.eql(u8, prefix.name, name)) return prefix.namespace;
        }
        return null;
    }

    fn peek(self: *Parser) ParseError!Token {
        if (self.lookahead == null) self.lookahead = try self.tokenizer.next();
        return self.lookahead.?;
    }

    fn take(self: *Parser) ParseError!Token {
        const token = try self.peek();
        self.lookahead = null;
        return token;
    }

    fn expect(self: *Parser, tag: TokenTag) ParseError!void {
        if ((try self.take()).tag != tag) return error.InvalidSyntax;
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == 0x20 or byte == 0x09 or byte == 0x0a or byte == 0x0d;
}

fn isDelimiter(byte: u8) bool {
    return isWhitespace(byte) or byte == '#' or byte == '{' or byte == '}' or
        byte == '.' or byte == '*' or byte == '<' or byte == '>' or byte == '?' or
        byte == '$' or byte == '(' or byte == ')' or byte == '[' or byte == ']' or
        byte == ';' or byte == ',';
}

fn isWordDelimiter(byte: u8) bool {
    return isWhitespace(byte) or byte == '#' or byte == '{' or byte == '}' or
        byte == '*' or byte == '<' or byte == '>' or byte == '?' or byte == '$' or
        byte == '(' or byte == ')' or byte == '[' or byte == ']' or byte == ';' or
        byte == ',';
}

fn utf8Length(input: []const u8, index: usize) ?usize {
    const length = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
    if (index + length > input.len) return null;
    _ = std.unicode.utf8Decode(input[index..][0..length]) catch return null;
    return length;
}

fn isVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    var index: usize = 0;
    var first = true;
    while (index < name.len) {
        const length = utf8Length(name, index) orelse return false;
        const codepoint = std.unicode.utf8Decode(name[index..][0..length]) catch return false;
        const allowed = if (first)
            isPnCharsU(codepoint) or (codepoint >= '0' and codepoint <= '9')
        else
            isPnCharsU(codepoint) or (codepoint >= '0' and codepoint <= '9') or
                codepoint == 0x00b7 or (codepoint >= 0x0300 and codepoint <= 0x036f) or
                (codepoint >= 0x203f and codepoint <= 0x2040);
        if (!allowed) return false;
        first = false;
        index += length;
    }
    return true;
}

fn isPnCharsU(codepoint: u21) bool {
    return codepoint == '_' or
        (codepoint >= 'A' and codepoint <= 'Z') or
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

fn isPrefixedName(value: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (!isPrefixLabel(value[0..colon])) return false;
    return isPnLocal(value[colon + 1 ..]);
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

fn isPnLocal(value: []const u8) bool {
    var index: usize = 0;
    var unit_index: usize = 0;
    var may_end = value.len == 0;
    while (index < value.len) : (unit_index += 1) {
        if (value[index] == '\\') {
            index += 1;
            if (index >= value.len or !isPnLocalEscaped(value[index])) return false;
            index += 1;
            may_end = true;
            continue;
        }
        if (value[index] == '%') {
            if (value.len - index < 3 or
                !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2]))
            {
                return false;
            }
            index += 3;
            may_end = true;
            continue;
        }
        const codepoint = nextCodepoint(value, &index) orelse return false;
        const allowed = if (unit_index == 0)
            isPnCharsU(codepoint) or codepoint == ':' or (codepoint >= '0' and codepoint <= '9')
        else
            isPnChars(codepoint) or codepoint == '.' or codepoint == ':';
        if (!allowed) return false;
        may_end = codepoint != '.';
    }
    return may_end;
}

fn appendDecodedPnLocal(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) ParseError!void {
    if (!isPnLocal(value)) return error.InvalidSyntax;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '\\') {
            index += 1;
            try output.append(allocator, value[index]);
            index += 1;
        } else if (value[index] == '%') {
            try output.appendSlice(allocator, value[index .. index + 3]);
            index += 3;
        } else {
            const start = index;
            _ = nextCodepoint(value, &index) orelse return error.InvalidSyntax;
            try output.appendSlice(allocator, value[start..index]);
        }
    }
}

fn nextCodepoint(value: []const u8, index: *usize) ?u21 {
    if (index.* >= value.len) return null;
    const length = utf8Length(value, index.*) orelse return null;
    const codepoint = std.unicode.utf8Decode(value[index.* .. index.* + length]) catch return null;
    index.* += length;
    return codepoint;
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

fn mapIriError(err: iri_mod.ResolveError) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.InvalidBase, error.InvalidReference => error.InvalidSyntax,
    };
}

test "tokenizer recognizes keywords variables IRIs comments and positions" {
    var tokenizer = try Tokenizer.init("# heading\nSeLeCt ?s WHERE { ?s <urn:p> $o . }");
    const expected = [_]TokenTag{
        .select,   .variable, .where,       .left_brace, .variable, .iri_reference,
        .variable, .dot,      .right_brace, .eof,
    };
    for (expected, 0..) |tag, index| {
        const token = try tokenizer.next();
        try std.testing.expectEqual(tag, token.tag);
        if (index == 0) try std.testing.expectEqual(@as(usize, 10), token.offset);
    }
}

test "parses SELECT projection and a basic graph pattern" {
    var query = try parseQuery(std.testing.allocator, "SELECT DISTINCT ?s $o WHERE { ?s <urn:p> $o . $o <urn:q> <urn:value> }");
    defer query.deinit();

    try std.testing.expectEqual(Modifier.distinct, query.modifier);
    const projection = query.projection();
    try std.testing.expectEqual(@as(usize, 2), projection.variables.len);
    try std.testing.expectEqualStrings("s", projection.variables[0]);
    try std.testing.expectEqual(@as(usize, 2), query.patterns().len);
    try std.testing.expectEqualStrings("urn:p", query.patterns()[0].predicate.iri);
    try std.testing.expectEqualStrings("o", query.patterns()[0].object.variable);
    try std.testing.expectEqualStrings("urn:value", query.patterns()[1].object.iri);
}

test "parses wildcard projection optional WHERE and an empty group" {
    var query = try parseQuery(std.testing.allocator, "select reduced * { # empty\n }");
    defer query.deinit();
    try std.testing.expectEqual(Modifier.reduced, query.modifier);
    try std.testing.expect(query.projection() == .all);
    try std.testing.expectEqual(@as(usize, 0), query.patterns().len);
}

test "parses BASE and PREFIX prologue and resolves graph terms" {
    var query = try parseQuery(
        std.testing.allocator,
        "BASE <https://example.com/root/>\n" ++
            "PREFIX ex: <vocab/>\n" ++
            "PREFIX : <https://default.example/>\n" ++
            "SELECT * WHERE { ex:subject :predicate <object> }",
    );
    defer query.deinit();

    try std.testing.expectEqualStrings("https://example.com/root/", query.base_iri.?);
    try std.testing.expectEqual(@as(usize, 2), query.prefixDeclarations().len);
    try std.testing.expectEqualStrings("ex", query.prefixDeclarations()[0].name);
    try std.testing.expectEqualStrings(
        "https://example.com/root/vocab/",
        query.prefixDeclarations()[0].namespace,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/root/vocab/subject",
        query.patterns()[0].subject.iri,
    );
    try std.testing.expectEqualStrings(
        "https://default.example/predicate",
        query.patterns()[0].predicate.iri,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/root/object",
        query.patterns()[0].object.iri,
    );
}

test "expands SPARQL prefixed-name escapes and uses the latest declaration" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://old.example/>\n" ++
            "PREFIX ex: <https://example.com/>\n" ++
            "SELECT * { ex:audio%3Atitle ex:a:b ex:c\\~z\\. }",
    );
    defer query.deinit();

    try std.testing.expectEqualStrings(
        "https://example.com/audio%3Atitle",
        query.patterns()[0].subject.iri,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/a:b",
        query.patterns()[0].predicate.iri,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/c~z.",
        query.patterns()[0].object.iri,
    );
}

test "lowers SELECT syntax to project over a BGP" {
    var query = try parseQuery(std.testing.allocator, "SELECT ?s WHERE { ?s <urn:p> <urn:o> }");
    defer query.deinit();
    const lowered = query.lower();
    try std.testing.expectEqual(@as(usize, 1), lowered.project.projection.variables.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.project.input.bgp.triples.len);
}

test "rejects malformed or unsupported query syntax" {
    const invalid = [_][]const u8{
        "",                                                     "SELECT WHERE {}",                    "SELECT * WHERE { ?s <urn:p> }",
        "SELECT * WHERE { ?s <urn:p> \"literal\" }",            "ASK {}",                             "SELECT * WHERE { ?s <broken iri> ?o }",
        "SELECT ?not-valid WHERE {}",                           "PREFIX ex:bad <urn:ex> SELECT * {}", "PREFIX bad <urn:ex> SELECT * {}",
        "PREFIX ex: <urn:ex> SELECT * { ex:s missing:p ex:o }", "BASE not-an-iri SELECT * {}",        "PREFIX ex: <urn:ex> SELECT * { ex:a%ZZ ex:p ex:o }",
        "PREFIX ex: <urn:ex> SELECT * { ex:a\\q ex:p ex:o }",
    };
    for (invalid) |input| {
        try std.testing.expectError(error.InvalidSyntax, parseQuery(std.testing.allocator, input));
    }
    try std.testing.expectError(
        error.InvalidUtf8,
        parseQuery(std.testing.allocator, "SELECT * WHERE { \xff }"),
    );
}

test "query parsing handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectQueryParses, .{
        "BASE <https://example.com/root/> PREFIX ex: <vocab/> " ++
            "SELECT DISTINCT ?s ?o WHERE { ?s ex:p ?o . ?o <relative> ex:value }",
    });
}

fn expectQueryParses(allocator: std.mem.Allocator, input: []const u8) !void {
    var query = try parseQuery(allocator, input);
    defer query.deinit();
    try std.testing.expectEqual(@as(usize, 2), query.patterns().len);
}

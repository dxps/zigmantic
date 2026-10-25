//! SPARQL 1.1 query syntax and algebra foundations.

const std = @import("std");
const iri_mod = @import("iri.zig");
const rdf_mod = @import("rdf.zig");

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
    blank_node_label,
    string_literal,
    language_tag,
    datatype_marker,
    integer,
    decimal,
    double,
    boolean,
    keyword_a,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
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
            '[' => self.single(.left_bracket),
            ']' => self.single(.right_bracket),
            '.' => if (self.index + 1 < self.input.len and
                std.ascii.isDigit(self.input[self.index + 1]))
                self.word(offset)
            else
                self.single(.dot),
            '*' => self.single(.star),
            '?', '$' => self.variable(),
            '<' => self.iriReference(),
            '"', '\'' => self.stringLiteral(),
            '@' => self.languageTag(),
            '^' => self.datatypeMarker(),
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
            if (byte == '\\') {
                self.index += 1;
                const digits: usize = if (self.index < self.input.len and self.input[self.index] == 'u')
                    4
                else if (self.index < self.input.len and self.input[self.index] == 'U')
                    8
                else
                    return error.InvalidSyntax;
                self.index += 1;
                if (self.input.len - self.index < digits) return error.InvalidSyntax;
                self.index += digits;
                continue;
            }
            if (byte <= 0x20 or byte == '<' or byte == '"' or byte == '{' or byte == '}' or
                byte == '|' or byte == '^' or byte == '`')
            {
                return error.InvalidSyntax;
            }
            self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
        }
        return error.InvalidSyntax;
    }

    fn stringLiteral(self: *Tokenizer) ParseError!Token {
        const offset = self.index;
        const quote = self.input[self.index];
        const long = self.index + 2 < self.input.len and
            self.input[self.index + 1] == quote and self.input[self.index + 2] == quote;
        const delimiter_length: usize = if (long) 3 else 1;
        self.index += delimiter_length;
        const value_start = self.index;

        while (self.index < self.input.len) {
            if (self.input[self.index] == '\\') {
                self.index += 1;
                if (self.index == self.input.len) return error.InvalidSyntax;
                self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
                continue;
            }
            if (!long and (self.input[self.index] == '\n' or self.input[self.index] == '\r')) {
                return error.InvalidSyntax;
            }
            if (self.input[self.index] == quote) {
                if (!long) {
                    const value = self.input[value_start..self.index];
                    self.index += 1;
                    return .{ .tag = .string_literal, .lexeme = value, .offset = offset };
                }
                if (self.index + 2 < self.input.len and
                    self.input[self.index + 1] == quote and
                    self.input[self.index + 2] == quote)
                {
                    const value = self.input[value_start..self.index];
                    self.index += 3;
                    return .{ .tag = .string_literal, .lexeme = value, .offset = offset };
                }
            }
            self.index += utf8Length(self.input, self.index) orelse return error.InvalidSyntax;
        }
        return error.InvalidSyntax;
    }

    fn languageTag(self: *Tokenizer) ParseError!Token {
        const offset = self.index;
        self.index += 1;
        const value_start = self.index;
        while (self.index < self.input.len and
            (std.ascii.isAlphanumeric(self.input[self.index]) or self.input[self.index] == '-'))
        {
            self.index += 1;
        }
        if (!isLanguageTag(self.input[value_start..self.index])) return error.InvalidSyntax;
        return .{
            .tag = .language_tag,
            .lexeme = self.input[value_start..self.index],
            .offset = offset,
        };
    }

    fn datatypeMarker(self: *Tokenizer) ParseError!Token {
        const offset = self.index;
        if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '^') {
            return error.InvalidSyntax;
        }
        self.index += 2;
        return .{ .tag = .datatype_marker, .lexeme = "^^", .offset = offset };
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
        else if (std.mem.eql(u8, lexeme, "a"))
            .keyword_a
        else if (std.mem.eql(u8, lexeme, "true") or std.mem.eql(u8, lexeme, "false"))
            .boolean
        else if (classifyNumeric(lexeme)) |numeric_tag|
            numeric_tag
        else if (std.mem.startsWith(u8, lexeme, "_:") and isBlankNodeLabel(lexeme[2..]))
            .blank_node_label
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
    blank_node: BlankNode,
    literal: Literal,
};

pub const BlankNode = union(enum) {
    labeled: []const u8,
    anonymous: usize,
};

pub const Literal = struct {
    lexical_form: []const u8,
    datatype: []const u8,
    language: ?[]const u8 = null,
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
    next_blank_node: usize = 0,

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
                .subject = try self.parseGraphTerm(),
                .predicate = try self.parsePredicate(),
                .object = try self.parseGraphTerm(),
            });
            const separator = try self.peek();
            if (separator.tag == .right_brace) return;
            if (separator.tag != .dot) return error.InvalidSyntax;
            _ = try self.take();
            if ((try self.peek()).tag == .right_brace) return;
        }
    }

    fn parseGraphTerm(self: *Parser) ParseError!PatternTerm {
        const token = try self.take();
        return switch (token.tag) {
            .variable => .{ .variable = try self.query.own(token.lexeme) },
            .iri_reference => .{ .iri = try self.resolveIri(token.lexeme) },
            .prefixed_name => .{ .iri = try self.expandPrefixedName(token.lexeme) },
            .blank_node_label => .{ .blank_node = .{
                .labeled = try self.query.own(token.lexeme[2..]),
            } },
            .left_bracket => self.parseAnonymousBlankNode(),
            .string_literal => .{ .literal = try self.parseStringLiteral(token.lexeme) },
            .integer => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_integer) },
            .decimal => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_decimal) },
            .double => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_double) },
            .boolean => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_namespace ++ "boolean") },
            else => error.InvalidSyntax,
        };
    }

    fn parsePredicate(self: *Parser) ParseError!PatternTerm {
        const token = try self.take();
        return switch (token.tag) {
            .variable => .{ .variable = try self.query.own(token.lexeme) },
            .iri_reference => .{ .iri = try self.resolveIri(token.lexeme) },
            .prefixed_name => .{ .iri = try self.expandPrefixedName(token.lexeme) },
            .keyword_a => .{ .iri = rdf_mod.rdf_namespace ++ "type" },
            else => error.InvalidSyntax,
        };
    }

    fn parseAnonymousBlankNode(self: *Parser) ParseError!PatternTerm {
        try self.expect(.right_bracket);
        const id = self.query.next_blank_node;
        self.query.next_blank_node += 1;
        return .{ .blank_node = .{ .anonymous = id } };
    }

    fn parseStringLiteral(self: *Parser, raw: []const u8) ParseError!Literal {
        const lexical_form = try self.decodeString(raw);
        const suffix = try self.peek();
        if (suffix.tag == .language_tag) {
            _ = try self.take();
            const language = try self.ownLowercase(suffix.lexeme);
            return .{
                .lexical_form = lexical_form,
                .datatype = rdf_mod.rdf_lang_string,
                .language = language,
            };
        }
        if (suffix.tag == .datatype_marker) {
            _ = try self.take();
            const datatype_token = try self.take();
            const datatype = switch (datatype_token.tag) {
                .iri_reference => try self.resolveIri(datatype_token.lexeme),
                .prefixed_name => try self.expandPrefixedName(datatype_token.lexeme),
                else => return error.InvalidSyntax,
            };
            return .{ .lexical_form = lexical_form, .datatype = datatype };
        }
        return .{ .lexical_form = lexical_form, .datatype = rdf_mod.xsd_string };
    }

    fn numericLiteral(
        self: *Parser,
        lexical_form: []const u8,
        datatype: []const u8,
    ) ParseError!Literal {
        return .{
            .lexical_form = try self.query.own(lexical_form),
            .datatype = datatype,
        };
    }

    fn decodeString(self: *Parser, raw: []const u8) ParseError![]const u8 {
        var decoded: std.ArrayList(u8) = .empty;
        errdefer decoded.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] != '\\') {
                const start = index;
                index += utf8Length(raw, index) orelse return error.InvalidSyntax;
                try decoded.appendSlice(self.allocator, raw[start..index]);
                continue;
            }
            index += 1;
            if (index >= raw.len) return error.InvalidSyntax;
            switch (raw[index]) {
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
        const owned = try decoded.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        try self.query.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn ownLowercase(self: *Parser, value: []const u8) ParseError![]const u8 {
        const owned = try self.allocator.alloc(u8, value.len);
        errdefer self.allocator.free(owned);
        for (value, 0..) |byte, index| owned[index] = std.ascii.toLower(byte);
        try self.query.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn resolveIri(self: *Parser, value: []const u8) ParseError![]const u8 {
        const decoded = try decodeIriReference(self.allocator, value);
        defer self.allocator.free(decoded);
        if (iri_mod.isAbsolute(decoded) or self.query.base_iri == null) {
            return self.query.own(decoded);
        }
        const resolved = iri_mod.resolveAlloc(
            self.allocator,
            self.query.base_iri.?,
            decoded,
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

fn classifyNumeric(value: []const u8) ?TokenTag {
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

fn isBlankNodeLabel(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    const first = nextCodepoint(value, &index) orelse return false;
    if (!(isPnCharsU(first) or (first >= '0' and first <= '9'))) return false;
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

fn decodeIriReference(allocator: std.mem.Allocator, raw: []const u8) ParseError![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\') {
            index += 1;
            try decodeUnicodeEscape(allocator, &decoded, raw, &index);
        } else {
            const start = index;
            index += utf8Length(raw, index) orelse return error.InvalidSyntax;
            try decoded.appendSlice(allocator, raw[start..index]);
        }
    }
    return decoded.toOwnedSlice(allocator);
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
        codepoint = codepoint * 16 +
            (std.fmt.charToDigit(digit, 16) catch return error.InvalidSyntax);
    }
    index.* += digits;
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) {
        return error.InvalidSyntax;
    }
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
        return error.InvalidSyntax;
    try output.appendSlice(allocator, encoded[0..length]);
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

test "parses blank nodes language literals and the rdf:type abbreviation" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { _:subject a \"hello\\nworld\"@EN-Latn . [] <urn:p> _:1_2_3_ }",
    );
    defer query.deinit();

    try std.testing.expectEqualStrings("subject", query.patterns()[0].subject.blank_node.labeled);
    try std.testing.expectEqualStrings(
        rdf_mod.rdf_namespace ++ "type",
        query.patterns()[0].predicate.iri,
    );
    const language_literal = query.patterns()[0].object.literal;
    try std.testing.expectEqualStrings("hello\nworld", language_literal.lexical_form);
    try std.testing.expectEqualStrings(rdf_mod.rdf_lang_string, language_literal.datatype);
    try std.testing.expectEqualStrings("en-latn", language_literal.language.?);
    try std.testing.expectEqual(@as(usize, 0), query.patterns()[1].subject.blank_node.anonymous);
    try std.testing.expectEqualStrings("1_2_3_", query.patterns()[1].object.blank_node.labeled);
}

test "parses typed string numeric and boolean literals" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> SELECT * { " ++
            "?s ex:a 'value'^^ex:kind . " ++
            "?s ex:b +42 . ?s ex:c -.5 . ?s ex:d 6.02e23 . ?s ex:e true }",
    );
    defer query.deinit();

    const typed = query.patterns()[0].object.literal;
    try std.testing.expectEqualStrings("value", typed.lexical_form);
    try std.testing.expectEqualStrings("https://example.com/kind", typed.datatype);
    try std.testing.expectEqualStrings(rdf_mod.xsd_integer, query.patterns()[1].object.literal.datatype);
    try std.testing.expectEqualStrings(rdf_mod.xsd_decimal, query.patterns()[2].object.literal.datatype);
    try std.testing.expectEqualStrings(rdf_mod.xsd_double, query.patterns()[3].object.literal.datatype);
    try std.testing.expectEqualStrings(
        rdf_mod.xsd_namespace ++ "boolean",
        query.patterns()[4].object.literal.datatype,
    );
}

test "decodes Unicode escapes in strings and IRI references" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { ?s <urn:\\u0070> '''\\U0001F46A''' }",
    );
    defer query.deinit();

    try std.testing.expectEqualStrings("urn:p", query.patterns()[0].predicate.iri);
    try std.testing.expectEqualStrings("👪", query.patterns()[0].object.literal.lexical_form);
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
        "",                                                     "SELECT WHERE {}",                               "SELECT * WHERE { ?s <urn:p> }",
        "SELECT * WHERE { ?s \"literal\" ?o }",                 "ASK {}",                                        "SELECT * WHERE { ?s <broken iri> ?o }",
        "SELECT ?not-valid WHERE {}",                           "PREFIX ex:bad <urn:ex> SELECT * {}",            "PREFIX bad <urn:ex> SELECT * {}",
        "PREFIX ex: <urn:ex> SELECT * { ex:s missing:p ex:o }", "BASE not-an-iri SELECT * {}",                   "PREFIX ex: <urn:ex> SELECT * { ex:a%ZZ ex:p ex:o }",
        "PREFIX ex: <urn:ex> SELECT * { ex:a\\q ex:p ex:o }",   "SELECT * { ?s <urn:p> \"bad\\q\" }",            "SELECT * { ?s <urn:p> \"unterminated }",
        "SELECT * { ?s <urn:p> \"value\"@en--US }",             "SELECT * { ?s <urn:p> \"value\"^^_:datatype }", "SELECT * { _:trailing. <urn:p> <urn:o> }",
        "SELECT * { ?s <urn:p> \"\\uD800\" }",                  "SELECT * { ?s <urn:\\U00110000> ?o }",
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
            "SELECT DISTINCT ?s ?o WHERE { _:s a \"hello\\n\"@EN . " ++
            "[] ex:p 12.5 . ?s <relative> \"value\"^^ex:kind }",
    });
}

fn expectQueryParses(allocator: std.mem.Allocator, input: []const u8) !void {
    var query = try parseQuery(allocator, input);
    defer query.deinit();
    try std.testing.expectEqual(@as(usize, 3), query.patterns().len);
}

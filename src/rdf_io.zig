//! Parsers and serializers for RDF concrete syntaxes.

const std = @import("std");
const rdf = @import("rdf.zig");

pub const Error = rdf.Error || error{InvalidSyntax};

/// Parses one complete RDF 1.1 N-Triples document into an owned graph.
pub fn parseNTriples(allocator: std.mem.Allocator, input: []const u8) Error!rdf.Graph {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var graph = rdf.Graph.init(allocator);
    errdefer graph.deinit();

    var parser = NTriplesParser{ .allocator = allocator, .input = input };
    try parser.parseInto(&graph);
    return graph;
}

const NTriplesParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn parseInto(self: *NTriplesParser, graph: *rdf.Graph) Error!void {
        try self.skipEmptyLinesAndComments();
        while (!self.atEnd()) {
            const subject = try self.parseSubject(&graph.terms);
            try self.requireHorizontalWhitespace();
            const predicate = try self.parseIri(&graph.terms);
            try self.requireHorizontalWhitespace();
            const object = try self.parseObject(&graph.terms);
            self.skipHorizontalWhitespace();
            try self.expect('.');
            self.skipHorizontalWhitespace();
            if (self.peek() == '#') self.skipComment();
            try self.consumeLineEndOrEof();

            _ = try graph.add(.{
                .subject = subject,
                .predicate = predicate,
                .object = object,
            });
            try self.skipEmptyLinesAndComments();
        }
    }

    fn parseSubject(self: *NTriplesParser, pool: *rdf.TermPool) Error!rdf.TermId {
        return switch (self.peek() orelse return error.InvalidSyntax) {
            '<' => self.parseIri(pool),
            '_' => self.parseBlankNode(pool),
            else => error.InvalidSyntax,
        };
    }

    fn parseObject(self: *NTriplesParser, pool: *rdf.TermPool) Error!rdf.TermId {
        return switch (self.peek() orelse return error.InvalidSyntax) {
            '<' => self.parseIri(pool),
            '_' => self.parseBlankNode(pool),
            '"' => self.parseLiteral(pool),
            else => error.InvalidSyntax,
        };
    }

    fn parseIri(self: *NTriplesParser, pool: *rdf.TermPool) Error!rdf.TermId {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.allocator);
        try self.parseIriValue(&value);
        return pool.internNamedNode(value.items) catch |err| return mapTermError(err);
    }

    fn parseIriValue(self: *NTriplesParser, value: *std.ArrayList(u8)) Error!void {
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

    fn parseBlankNode(self: *NTriplesParser, pool: *rdf.TermPool) Error!rdf.TermId {
        try self.expect('_');
        try self.expect(':');
        const start = self.index;
        const first = self.peek() orelse return error.InvalidSyntax;
        if (!isBlankFirst(first)) return error.InvalidSyntax;
        self.index += 1;

        while (self.peek()) |byte| {
            if (!isBlankRest(byte)) break;
            self.index += 1;
        }
        if (self.input[self.index - 1] == '.') self.index -= 1;
        if (self.index == start) return error.InvalidSyntax;
        return pool.internBlankNode(self.input[start..self.index]) catch |err| return mapTermError(err);
    }

    fn parseLiteral(self: *NTriplesParser, pool: *rdf.TermPool) Error!rdf.TermId {
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

    fn parseLanguageTag(self: *NTriplesParser) Error![]const u8 {
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

    fn parseStringEscape(self: *NTriplesParser, output: *std.ArrayList(u8)) Error!void {
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

    fn parseUnicodeEscape(self: *NTriplesParser, output: *std.ArrayList(u8)) Error!void {
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

    fn skipEmptyLinesAndComments(self: *NTriplesParser) Error!void {
        while (true) {
            self.skipHorizontalWhitespace();
            if (self.peek() == '#') self.skipComment();
            if (try self.consumeLineEnd()) continue;
            return;
        }
    }

    fn skipHorizontalWhitespace(self: *NTriplesParser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t') return;
            self.index += 1;
        }
    }

    fn requireHorizontalWhitespace(self: *NTriplesParser) Error!void {
        const start = self.index;
        self.skipHorizontalWhitespace();
        if (self.index == start) return error.InvalidSyntax;
    }

    fn skipComment(self: *NTriplesParser) void {
        while (self.peek()) |byte| {
            if (byte == '\n' or byte == '\r') return;
            self.index += 1;
        }
    }

    fn consumeLineEndOrEof(self: *NTriplesParser) Error!void {
        if (self.atEnd()) return;
        if (!(try self.consumeLineEnd())) return error.InvalidSyntax;
    }

    fn consumeLineEnd(self: *NTriplesParser) Error!bool {
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

    fn expect(self: *NTriplesParser, expected: u8) Error!void {
        if (self.peek() != expected) return error.InvalidSyntax;
        self.index += 1;
    }

    fn peek(self: *const NTriplesParser) ?u8 {
        if (self.atEnd()) return null;
        return self.input[self.index];
    }

    fn atEnd(self: *const NTriplesParser) bool {
        return self.index >= self.input.len;
    }
};

fn isBlankFirst(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn isBlankRest(byte: u8) bool {
    return isBlankFirst(byte) or byte == '-' or byte == '.';
}

fn mapTermError(err: rdf.Error) Error {
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

test "N-Triples rejects malformed documents" {
    const invalid = [_][]const u8{
        "<relative> <https://example.com/p> <https://example.com/o> .\n",
        "<https://example.com/s><https://example.com/p> \"o\" .\n",
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
}

test "N-Triples parser handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNTriplesAllocations,
        .{},
    );
}

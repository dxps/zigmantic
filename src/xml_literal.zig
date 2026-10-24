//! Validation for the `rdf:XMLLiteral` lexical space.

const std = @import("std");

const xml_namespace = "http://www.w3.org/XML/1998/namespace";
const xmlns_namespace = "http://www.w3.org/2000/xmlns/";

const Name = struct {
    qualified: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
};

const Binding = struct {
    prefix: []const u8,
    uri: []const u8,
};

const Element = struct {
    name: []const u8,
    binding_base: usize,
};

const Attribute = struct {
    name: Name,
};

/// Reports whether `input` is well-balanced, self-contained XML 1.0 content
/// whose enclosing element would conform to Namespaces in XML 1.0.
pub fn validate(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!bool {
    var parser = Parser.init(allocator, input);
    defer parser.deinit();
    return parser.parse();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    elements: std.ArrayList(Element) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *Parser) void {
        self.elements.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
        self.arena.deinit();
    }

    fn parse(self: *Parser) std.mem.Allocator.Error!bool {
        while (self.index < self.input.len) {
            if (self.input[self.index] != '<') {
                if (!try self.parseCharacterData()) return false;
            } else if (self.startsWith("<!--")) {
                if (!self.parseComment()) return false;
            } else if (self.startsWith("<![CDATA[")) {
                if (!self.parseCdata()) return false;
            } else if (self.startsWith("<?")) {
                if (!self.parseProcessingInstruction()) return false;
            } else if (self.startsWith("</")) {
                if (!self.parseEndTag()) return false;
            } else if (self.startsWith("<!")) {
                return false;
            } else {
                if (!try self.parseStartTag()) return false;
            }
        }
        return self.elements.items.len == 0;
    }

    fn parseCharacterData(self: *Parser) std.mem.Allocator.Error!bool {
        while (self.index < self.input.len and self.input[self.index] != '<') {
            if (self.startsWith("]]>")) return false;
            if (self.input[self.index] == '&') {
                if (!try self.parseReference(null)) return false;
            } else if (!self.consumeXmlChar()) {
                return false;
            }
        }
        return true;
    }

    fn parseComment(self: *Parser) bool {
        self.index += 4;
        while (self.index < self.input.len) {
            if (self.startsWith("-->")) {
                self.index += 3;
                return true;
            }
            if (self.startsWith("--") or !self.consumeXmlChar()) return false;
        }
        return false;
    }

    fn parseCdata(self: *Parser) bool {
        self.index += "<![CDATA[".len;
        while (self.index < self.input.len) {
            if (self.startsWith("]]>")) {
                self.index += 3;
                return true;
            }
            if (!self.consumeXmlChar()) return false;
        }
        return false;
    }

    fn parseProcessingInstruction(self: *Parser) bool {
        self.index += 2;
        const target = self.parseXmlName(false) orelse return false;
        if (std.ascii.eqlIgnoreCase(target.qualified, "xml")) return false;
        if (self.startsWith("?>")) {
            self.index += 2;
            return true;
        }
        if (!self.consumeWhitespace()) return false;
        while (self.index < self.input.len) {
            if (self.startsWith("?>")) {
                self.index += 2;
                return true;
            }
            if (!self.consumeXmlChar()) return false;
        }
        return false;
    }

    fn parseStartTag(self: *Parser) std.mem.Allocator.Error!bool {
        std.debug.assert(self.input[self.index] == '<');
        self.index += 1;
        const element_name = self.parseXmlName(true) orelse return false;
        const binding_base = self.bindings.items.len;
        const attribute_base = self.attributes.items.len;
        errdefer {
            self.bindings.shrinkRetainingCapacity(binding_base);
            self.attributes.shrinkRetainingCapacity(attribute_base);
        }

        var empty = false;
        while (true) {
            const had_whitespace = self.consumeWhitespace();
            if (self.startsWith("/>")) {
                self.index += 2;
                empty = true;
                break;
            }
            if (self.startsWith(">")) {
                self.index += 1;
                break;
            }
            if (!had_whitespace) return false;

            const attribute_name = self.parseXmlName(true) orelse return false;
            for (self.attributes.items[attribute_base..]) |attribute| {
                if (std.mem.eql(u8, attribute.name.qualified, attribute_name.qualified)) return false;
            }
            self.skipWhitespace();
            if (!self.consumeByte('=')) return false;
            self.skipWhitespace();
            const value = (try self.parseAttributeValue()) orelse return false;

            if (std.mem.eql(u8, attribute_name.qualified, "xmlns")) {
                if (!try self.addBinding(binding_base, "", value)) return false;
            } else if (attribute_name.prefix) |prefix| {
                if (std.mem.eql(u8, prefix, "xmlns")) {
                    if (!try self.addBinding(binding_base, attribute_name.local, value)) return false;
                } else {
                    try self.attributes.append(self.allocator, .{ .name = attribute_name });
                }
            } else {
                try self.attributes.append(self.allocator, .{ .name = attribute_name });
            }
        }

        if (element_name.prefix) |prefix| {
            if (self.resolvePrefix(prefix) == null) return false;
        }
        for (self.attributes.items[attribute_base..], 0..) |attribute, index| {
            if (attribute.name.prefix) |prefix| {
                if (std.mem.eql(u8, prefix, "xmlns") or self.resolvePrefix(prefix) == null)
                    return false;
            }
            const uri = self.attributeNamespace(attribute.name) orelse return false;
            for (self.attributes.items[attribute_base..][0..index]) |previous| {
                const previous_uri = self.attributeNamespace(previous.name) orelse return false;
                if (std.mem.eql(u8, uri, previous_uri) and
                    std.mem.eql(u8, attribute.name.local, previous.name.local)) return false;
            }
        }
        self.attributes.shrinkRetainingCapacity(attribute_base);

        if (empty) {
            self.bindings.shrinkRetainingCapacity(binding_base);
        } else {
            try self.elements.append(self.allocator, .{
                .name = element_name.qualified,
                .binding_base = binding_base,
            });
        }
        return true;
    }

    fn parseEndTag(self: *Parser) bool {
        if (self.elements.items.len == 0) return false;
        self.index += 2;
        const name = self.parseXmlName(true) orelse return false;
        self.skipWhitespace();
        if (!self.consumeByte('>')) return false;
        const element = self.elements.pop().?;
        if (!std.mem.eql(u8, name.qualified, element.name)) return false;
        self.bindings.shrinkRetainingCapacity(element.binding_base);
        return true;
    }

    fn parseAttributeValue(self: *Parser) std.mem.Allocator.Error!?[]const u8 {
        if (self.index >= self.input.len) return null;
        const quote = self.input[self.index];
        if (quote != '\'' and quote != '"') return null;
        self.index += 1;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        while (self.index < self.input.len and self.input[self.index] != quote) {
            if (self.input[self.index] == '<') return null;
            if (self.input[self.index] == '&') {
                if (!try self.parseReference(&decoded)) return null;
            } else {
                const start = self.index;
                const character = self.decodeCodepoint() orelse return null;
                if (!isXmlChar(character.codepoint)) return null;
                self.index += character.length;
                if (character.codepoint == 0x0d and self.consumeByte(0x0a)) {
                    try decoded.append(self.allocator, ' ');
                } else if (character.codepoint == 0x09 or character.codepoint == 0x0a or
                    character.codepoint == 0x0d)
                {
                    try decoded.append(self.allocator, ' ');
                } else {
                    try decoded.appendSlice(self.allocator, self.input[start..self.index]);
                }
            }
        }
        if (!self.consumeByte(quote)) return null;
        return try self.arena.allocator().dupe(u8, decoded.items);
    }

    fn parseReference(
        self: *Parser,
        output: ?*std.ArrayList(u8),
    ) std.mem.Allocator.Error!bool {
        std.debug.assert(self.input[self.index] == '&');
        self.index += 1;
        var codepoint: ?u21 = null;
        if (self.consumeByte('#')) {
            var radix: u8 = 10;
            if (self.consumeByte('x')) radix = 16;
            const digits_start = self.index;
            var value: u32 = 0;
            while (self.index < self.input.len and self.input[self.index] != ';') {
                const digit = std.fmt.charToDigit(self.input[self.index], radix) catch return false;
                value = std.math.mul(u32, value, radix) catch return false;
                value = std.math.add(u32, value, digit) catch return false;
                self.index += 1;
            }
            if (self.index == digits_start or value > 0x10ffff or !isXmlChar(@intCast(value))) return false;
            codepoint = @intCast(value);
        } else {
            const name_start = self.index;
            while (self.index < self.input.len and self.input[self.index] != ';') self.index += 1;
            const name = self.input[name_start..self.index];
            codepoint = if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "apos")) '\'' else if (std.mem.eql(u8, name, "quot")) '"' else return false;
        }
        if (!self.consumeByte(';')) return false;
        if (output) |bytes| {
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint.?, &buffer) catch return false;
            try bytes.appendSlice(self.allocator, buffer[0..length]);
        }
        return true;
    }

    fn addBinding(self: *Parser, base: usize, prefix: []const u8, uri: []const u8) std.mem.Allocator.Error!bool {
        for (self.bindings.items[base..]) |binding| {
            if (std.mem.eql(u8, binding.prefix, prefix)) return false;
        }
        if (std.mem.eql(u8, prefix, "xmlns") or std.mem.eql(u8, uri, xmlns_namespace)) return false;
        if (std.mem.eql(u8, prefix, "xml") != std.mem.eql(u8, uri, xml_namespace)) return false;
        if (prefix.len != 0 and uri.len == 0) return false;
        try self.bindings.append(self.allocator, .{ .prefix = prefix, .uri = uri });
        return true;
    }

    fn resolvePrefix(self: *const Parser, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return xml_namespace;
        var index = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = self.bindings.items[index];
            if (std.mem.eql(u8, binding.prefix, prefix)) return binding.uri;
        }
        return null;
    }

    fn attributeNamespace(self: *const Parser, name: Name) ?[]const u8 {
        const prefix = name.prefix orelse return "";
        return self.resolvePrefix(prefix);
    }

    fn parseXmlName(self: *Parser, qname: bool) ?Name {
        const start = self.index;
        const first = self.decodeCodepoint() orelse return null;
        if (!isNameStart(first.codepoint)) return null;
        self.index += first.length;
        while (self.decodeCodepoint()) |decoded| {
            if (!isNameChar(decoded.codepoint)) break;
            self.index += decoded.length;
        }
        const qualified = self.input[start..self.index];
        if (!qname) {
            if (!isNcName(qualified)) return null;
            return .{ .qualified = qualified, .prefix = null, .local = qualified };
        }
        const colon = std.mem.indexOfScalar(u8, qualified, ':');
        if (colon) |position| {
            if (position == 0 or position + 1 == qualified.len or
                std.mem.indexOfScalar(u8, qualified[position + 1 ..], ':') != null or
                !isNcName(qualified[0..position]) or !isNcName(qualified[position + 1 ..])) return null;
            return .{
                .qualified = qualified,
                .prefix = qualified[0..position],
                .local = qualified[position + 1 ..],
            };
        }
        if (!isNcName(qualified)) return null;
        return .{ .qualified = qualified, .prefix = null, .local = qualified };
    }

    fn consumeWhitespace(self: *Parser) bool {
        const start = self.index;
        self.skipWhitespace();
        return self.index != start;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.input.len and isWhitespace(self.input[self.index])) self.index += 1;
    }

    fn consumeByte(self: *Parser, byte: u8) bool {
        if (self.index >= self.input.len or self.input[self.index] != byte) return false;
        self.index += 1;
        return true;
    }

    fn startsWith(self: *const Parser, value: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.index..], value);
    }

    fn consumeXmlChar(self: *Parser) bool {
        const decoded = self.decodeCodepoint() orelse return false;
        if (!isXmlChar(decoded.codepoint)) return false;
        self.index += decoded.length;
        return true;
    }

    const Decoded = struct { codepoint: u21, length: usize };

    fn decodeCodepoint(self: *const Parser) ?Decoded {
        if (self.index >= self.input.len) return null;
        const length = std.unicode.utf8ByteSequenceLength(self.input[self.index]) catch return null;
        if (self.index + length > self.input.len) return null;
        const codepoint = std.unicode.utf8Decode(self.input[self.index..][0..length]) catch return null;
        return .{ .codepoint = codepoint, .length = length };
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == 0x20 or byte == 0x09 or byte == 0x0a or byte == 0x0d;
}

fn isXmlChar(codepoint: u21) bool {
    return codepoint == 0x09 or codepoint == 0x0a or codepoint == 0x0d or
        (codepoint >= 0x20 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

fn isNameStart(codepoint: u21) bool {
    return codepoint == ':' or codepoint == '_' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0xc0 and codepoint <= 0xd6) or
        (codepoint >= 0xd8 and codepoint <= 0xf6) or
        (codepoint >= 0xf8 and codepoint <= 0x2ff) or
        (codepoint >= 0x370 and codepoint <= 0x37d) or
        (codepoint >= 0x37f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

fn isNameChar(codepoint: u21) bool {
    return isNameStart(codepoint) or codepoint == '-' or codepoint == '.' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0xb7 or
        (codepoint >= 0x300 and codepoint <= 0x36f) or
        (codepoint >= 0x203f and codepoint <= 0x2040);
}

fn isNcName(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    var first = true;
    while (index < value.len) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch return false;
        if (index + length > value.len) return false;
        const codepoint = std.unicode.utf8Decode(value[index..][0..length]) catch return false;
        if (codepoint == ':' or if (first) !isNameStart(codepoint) else !isNameChar(codepoint))
            return false;
        first = false;
        index += length;
    }
    return true;
}

test "accepts well-balanced self-contained XML content" {
    try std.testing.expect(try validate(std.testing.allocator, "text<!-- note --><a xmlns='urn:a' p='&amp;'>&#x20;<b/></a><![CDATA[<raw>]]>"));
    try std.testing.expect(try validate(std.testing.allocator, "<p:a xmlns:p='urn:a' p:x='1'/><?target data?>"));
}

test "rejects malformed XML content" {
    const invalid = [_][]const u8{
        "<",                "<a>",                  "<a></b>",     "<1a/>",                 "<a x=\"1\" x=\"2\"/>",
        "<a>&unknown;</a>", "<a><!-- a--b --></a>", "text]]>tail", "<?xml version='1.0'?>", "<!DOCTYPE a>",
        "<p:1/>",           "<?p:target?>",         "\x00",
    };
    for (invalid) |value| try std.testing.expect(!try validate(std.testing.allocator, value));
}

test "enforces self-contained namespace use and expanded attribute uniqueness" {
    try std.testing.expect(!try validate(std.testing.allocator, "<p:a/>"));
    try std.testing.expect(!try validate(std.testing.allocator, "<a xmlns:p='urn:x' xmlns:q='urn:x' p:x='1' q:x='2'/>"));
    try std.testing.expect(!try validate(std.testing.allocator, "<a xmlns:xml='urn:not-xml'/>"));
    try std.testing.expect(!try validate(std.testing.allocator, "<a xmlns='http://www.w3.org/XML/1998/namespace'/>"));
    try std.testing.expect(!try validate(std.testing.allocator, "<a xmlns:p='urn:x' xmlns:q='urn:&#120;' p:x='1' q:x='2'/>"));
    try std.testing.expect(try validate(std.testing.allocator, "<a xmlns:p='urn:x'><p:b xml:lang='en'/></a>"));
}

test "propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectValid, .{
        "<a xmlns:p='urn:x' p:value='ok'><p:b/></a>",
    });
}

fn expectValid(allocator: std.mem.Allocator, input: []const u8) !void {
    try std.testing.expect(try validate(allocator, input));
}

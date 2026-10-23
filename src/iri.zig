//! IRI-reference utilities shared by RDF concrete syntaxes.
//!
//! Resolution follows RFC 3986 section 5.2. RFC 3987 section 6.5 applies
//! that algorithm directly to IRI references, treating additional Unicode
//! characters like unreserved URI characters.

const std = @import("std");

pub const ResolveError = std.mem.Allocator.Error || error{
    InvalidBase,
    InvalidReference,
    InvalidUtf8,
};

/// Resolves `reference` against an absolute `base` and returns owned UTF-8.
/// This performs reference resolution, not IRI normalization.
pub fn resolveAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    reference: []const u8,
) ResolveError![]u8 {
    const base_components = parseReference(base) catch |err| return switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.InvalidReference => error.InvalidBase,
    };
    if (base_components.scheme == null) return error.InvalidBase;
    const ref = try parseReference(reference);

    var target_path: std.ArrayList(u8) = .empty;
    defer target_path.deinit(allocator);

    var scheme: []const u8 = undefined;
    var authority: ?[]const u8 = null;
    var query: ?[]const u8 = null;

    if (ref.scheme) |ref_scheme| {
        scheme = ref_scheme;
        authority = ref.authority;
        try removeDotSegments(allocator, &target_path, ref.path);
        query = ref.query;
    } else {
        scheme = base_components.scheme.?;
        if (ref.authority) |ref_authority| {
            authority = ref_authority;
            try removeDotSegments(allocator, &target_path, ref.path);
            query = ref.query;
        } else {
            authority = base_components.authority;
            if (ref.path.len == 0) {
                try target_path.appendSlice(allocator, base_components.path);
                query = ref.query orelse base_components.query;
            } else {
                if (ref.path[0] == '/') {
                    try removeDotSegments(allocator, &target_path, ref.path);
                } else {
                    var merged: std.ArrayList(u8) = .empty;
                    defer merged.deinit(allocator);
                    try mergePaths(allocator, &merged, base_components, ref.path);
                    try removeDotSegments(allocator, &target_path, merged.items);
                }
                query = ref.query;
            }
        }
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, scheme);
    try result.append(allocator, ':');
    if (authority) |value| {
        try result.appendSlice(allocator, "//");
        try result.appendSlice(allocator, value);
    }
    try result.appendSlice(allocator, target_path.items);
    if (query) |value| {
        try result.append(allocator, '?');
        try result.appendSlice(allocator, value);
    }
    if (ref.fragment) |value| {
        try result.append(allocator, '#');
        try result.appendSlice(allocator, value);
    }
    return result.toOwnedSlice(allocator);
}

const Components = struct {
    scheme: ?[]const u8,
    authority: ?[]const u8,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
};

const ReferenceError = error{ InvalidReference, InvalidUtf8 };

fn parseReference(value: []const u8) ReferenceError!Components {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    try validateCharacters(value);

    const fragment_at = std.mem.indexOfScalar(u8, value, '#');
    const before_fragment = if (fragment_at) |index| value[0..index] else value;
    const fragment = if (fragment_at) |index| value[index + 1 ..] else null;

    const query_at = std.mem.indexOfScalar(u8, before_fragment, '?');
    const hierarchy = if (query_at) |index| before_fragment[0..index] else before_fragment;
    const query = if (query_at) |index| before_fragment[index + 1 ..] else null;

    var scheme: ?[]const u8 = null;
    var hierarchy_start: usize = 0;
    if (std.mem.indexOfScalar(u8, hierarchy, ':')) |colon| {
        const slash = std.mem.indexOfScalar(u8, hierarchy, '/');
        if (slash == null or colon < slash.?) {
            if (!isScheme(hierarchy[0..colon])) return error.InvalidReference;
            scheme = hierarchy[0..colon];
            hierarchy_start = colon + 1;
        }
    }

    const remainder = hierarchy[hierarchy_start..];
    var authority: ?[]const u8 = null;
    var path_start: usize = hierarchy_start;
    if (std.mem.startsWith(u8, remainder, "//")) {
        const authority_start = hierarchy_start + 2;
        const authority_end = std.mem.indexOfScalarPos(u8, hierarchy, authority_start, '/') orelse
            hierarchy.len;
        authority = hierarchy[authority_start..authority_end];
        path_start = authority_end;
    }

    return .{
        .scheme = scheme,
        .authority = authority,
        .path = hierarchy[path_start..],
        .query = query,
        .fragment = fragment,
    };
}

fn validateCharacters(value: []const u8) ReferenceError!void {
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidReference;
        switch (byte) {
            '<', '>', '"', '{', '}', '|', '\\', '^', '`' => return error.InvalidReference,
            '%' => {
                if (value.len - index < 3 or
                    std.fmt.charToDigit(value[index + 1], 16) == error.InvalidCharacter or
                    std.fmt.charToDigit(value[index + 2], 16) == error.InvalidCharacter)
                {
                    return error.InvalidReference;
                }
                index += 3;
            },
            else => index += 1,
        }
    }
}

fn isScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) {
            return false;
        }
    }
    return true;
}

fn mergePaths(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    base: Components,
    reference_path: []const u8,
) std.mem.Allocator.Error!void {
    if (base.authority != null and base.path.len == 0) {
        try output.append(allocator, '/');
    } else if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |slash| {
        try output.appendSlice(allocator, base.path[0 .. slash + 1]);
    }
    try output.appendSlice(allocator, reference_path);
}

fn removeDotSegments(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    path: []const u8,
) std.mem.Allocator.Error!void {
    var index: usize = 0;
    while (index < path.len) {
        const remaining = path[index..];
        if (std.mem.startsWith(u8, remaining, "../")) {
            index += 3;
        } else if (std.mem.startsWith(u8, remaining, "./")) {
            index += 2;
        } else if (std.mem.startsWith(u8, remaining, "/./")) {
            index += 2;
        } else if (std.mem.eql(u8, remaining, "/.")) {
            try output.append(allocator, '/');
            index = path.len;
        } else if (std.mem.startsWith(u8, remaining, "/../")) {
            index += 3;
            removeLastSegment(output);
        } else if (std.mem.eql(u8, remaining, "/..")) {
            removeLastSegment(output);
            try output.append(allocator, '/');
            index = path.len;
        } else if (std.mem.eql(u8, remaining, ".") or std.mem.eql(u8, remaining, "..")) {
            index = path.len;
        } else {
            const segment_end = if (remaining[0] == '/')
                (std.mem.indexOfScalarPos(u8, path, index + 1, '/') orelse path.len)
            else
                (std.mem.indexOfScalarPos(u8, path, index, '/') orelse path.len);
            try output.appendSlice(allocator, path[index..segment_end]);
            index = segment_end;
        }
    }
}

fn removeLastSegment(output: *std.ArrayList(u8)) void {
    const new_length = std.mem.lastIndexOfScalar(u8, output.items, '/') orelse 0;
    output.shrinkRetainingCapacity(new_length);
}

test "RFC 3986 normal reference resolution examples" {
    const Example = struct { reference: []const u8, expected: []const u8 };
    const examples = [_]Example{
        .{ .reference = "g:h", .expected = "g:h" },
        .{ .reference = "g", .expected = "http://a/b/c/g" },
        .{ .reference = "./g", .expected = "http://a/b/c/g" },
        .{ .reference = "g/", .expected = "http://a/b/c/g/" },
        .{ .reference = "/g", .expected = "http://a/g" },
        .{ .reference = "//g", .expected = "http://g" },
        .{ .reference = "?y", .expected = "http://a/b/c/d;p?y" },
        .{ .reference = "g?y", .expected = "http://a/b/c/g?y" },
        .{ .reference = "#s", .expected = "http://a/b/c/d;p?q#s" },
        .{ .reference = "g#s", .expected = "http://a/b/c/g#s" },
        .{ .reference = "g?y#s", .expected = "http://a/b/c/g?y#s" },
        .{ .reference = ";x", .expected = "http://a/b/c/;x" },
        .{ .reference = "g;x", .expected = "http://a/b/c/g;x" },
        .{ .reference = "g;x?y#s", .expected = "http://a/b/c/g;x?y#s" },
        .{ .reference = "", .expected = "http://a/b/c/d;p?q" },
        .{ .reference = ".", .expected = "http://a/b/c/" },
        .{ .reference = "./", .expected = "http://a/b/c/" },
        .{ .reference = "..", .expected = "http://a/b/" },
        .{ .reference = "../", .expected = "http://a/b/" },
        .{ .reference = "../g", .expected = "http://a/b/g" },
        .{ .reference = "../..", .expected = "http://a/" },
        .{ .reference = "../../", .expected = "http://a/" },
        .{ .reference = "../../g", .expected = "http://a/g" },
    };
    for (examples) |example| {
        const actual = try resolveAlloc(std.testing.allocator, "http://a/b/c/d;p?q", example.reference);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(example.expected, actual);
    }
}

test "RFC 3986 abnormal dot-segment examples" {
    const Example = struct { reference: []const u8, expected: []const u8 };
    const examples = [_]Example{
        .{ .reference = "../../../g", .expected = "http://a/g" },
        .{ .reference = "../../../../g", .expected = "http://a/g" },
        .{ .reference = "/./g", .expected = "http://a/g" },
        .{ .reference = "/../g", .expected = "http://a/g" },
        .{ .reference = "g.", .expected = "http://a/b/c/g." },
        .{ .reference = ".g", .expected = "http://a/b/c/.g" },
        .{ .reference = "g..", .expected = "http://a/b/c/g.." },
        .{ .reference = "..g", .expected = "http://a/b/c/..g" },
        .{ .reference = "./../g", .expected = "http://a/b/g" },
        .{ .reference = "./g/.", .expected = "http://a/b/c/g/" },
        .{ .reference = "g/./h", .expected = "http://a/b/c/g/h" },
        .{ .reference = "g/../h", .expected = "http://a/b/c/h" },
        .{ .reference = "g;x=1/./y", .expected = "http://a/b/c/g;x=1/y" },
        .{ .reference = "g;x=1/../y", .expected = "http://a/b/c/y" },
        .{ .reference = "g?y/./x", .expected = "http://a/b/c/g?y/./x" },
        .{ .reference = "g?y/../x", .expected = "http://a/b/c/g?y/../x" },
        .{ .reference = "g#s/./x", .expected = "http://a/b/c/g#s/./x" },
        .{ .reference = "g#s/../x", .expected = "http://a/b/c/g#s/../x" },
        .{ .reference = "http:g", .expected = "http:g" },
    };
    for (examples) |example| {
        const actual = try resolveAlloc(std.testing.allocator, "http://a/b/c/d;p?q", example.reference);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(example.expected, actual);
    }
}

test "IRI resolution preserves Unicode and validates inputs" {
    const resolved = try resolveAlloc(
        std.testing.allocator,
        "https://例え.example/ディレクトリ/file",
        "../資料/項目?名前=値#節",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "https://例え.example/資料/項目?名前=値#節",
        resolved,
    );

    try std.testing.expectError(
        error.InvalidBase,
        resolveAlloc(std.testing.allocator, "relative/base", "item"),
    );
    try std.testing.expectError(
        error.InvalidReference,
        resolveAlloc(std.testing.allocator, "https://example.com/base", "bad%escape"),
    );
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(
        error.InvalidUtf8,
        resolveAlloc(std.testing.allocator, "https://example.com/base", &invalid_utf8),
    );
}

fn exerciseResolutionAllocations(allocator: std.mem.Allocator) !void {
    const resolved = try resolveAlloc(
        allocator,
        "https://example.com/a/b/c?query",
        "../../資料/item?new#fragment",
    );
    defer allocator.free(resolved);
}

test "IRI resolution handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseResolutionAllocations,
        .{},
    );
}

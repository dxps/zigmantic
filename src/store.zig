//! Indexed, in-memory RDF dataset storage.

const std = @import("std");
const rdf = @import("rdf.zig");

const PostingList = std.ArrayList(usize);
const TermIndex = std.AutoHashMapUnmanaged(rdf.TermId, PostingList);
const GraphIndex = std.AutoHashMapUnmanaged(u64, PostingList);

const QuadKey = struct {
    subject: u32,
    predicate: u32,
    object: u32,
    graph: u64,
};

const Slot = struct {
    quad: rdf.Quad,
    active: bool = true,
};

const PostingMutation = struct {
    created: bool,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    terms: rdf.TermPool,
    slots: std.ArrayList(Slot) = .empty,
    active_quads: std.AutoHashMapUnmanaged(QuadKey, usize) = .empty,
    subject_index: TermIndex = .empty,
    predicate_index: TermIndex = .empty,
    object_index: TermIndex = .empty,
    graph_index: GraphIndex = .empty,
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .terms = .init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        deinitIndex(rdf.TermId, &self.subject_index, self.allocator);
        deinitIndex(rdf.TermId, &self.predicate_index, self.allocator);
        deinitIndex(rdf.TermId, &self.object_index, self.allocator);
        deinitIndex(u64, &self.graph_index, self.allocator);
        self.active_quads.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.terms.deinit();
        self.* = undefined;
    }

    /// Inserts a pool-local quad. Returns false when the exact quad already exists.
    /// Allocation failure leaves the store's logical contents unchanged.
    pub fn add(self: *Store, quad: rdf.Quad) rdf.Error!bool {
        try rdf.validateTriple(&self.terms, .{
            .subject = quad.subject,
            .predicate = quad.predicate,
            .object = quad.object,
        });
        try rdf.validateGraphName(&self.terms, quad.graph_name);

        const key = quadKey(quad);
        if (self.active_quads.contains(key)) return false;

        const slot_index = self.slots.items.len;
        try self.slots.append(self.allocator, .{ .quad = quad });
        errdefer _ = self.slots.pop();

        const subject_mutation = try appendPosting(
            rdf.TermId,
            &self.subject_index,
            self.allocator,
            quad.subject,
            slot_index,
        );
        errdefer undoPosting(
            rdf.TermId,
            &self.subject_index,
            self.allocator,
            quad.subject,
            subject_mutation,
        );

        const predicate_mutation = try appendPosting(
            rdf.TermId,
            &self.predicate_index,
            self.allocator,
            quad.predicate,
            slot_index,
        );
        errdefer undoPosting(
            rdf.TermId,
            &self.predicate_index,
            self.allocator,
            quad.predicate,
            predicate_mutation,
        );

        const object_mutation = try appendPosting(
            rdf.TermId,
            &self.object_index,
            self.allocator,
            quad.object,
            slot_index,
        );
        errdefer undoPosting(
            rdf.TermId,
            &self.object_index,
            self.allocator,
            quad.object,
            object_mutation,
        );

        const graph_key = graphKey(quad.graph_name);
        const graph_mutation = try appendPosting(
            u64,
            &self.graph_index,
            self.allocator,
            graph_key,
            slot_index,
        );
        errdefer undoPosting(
            u64,
            &self.graph_index,
            self.allocator,
            graph_key,
            graph_mutation,
        );

        try self.active_quads.put(self.allocator, key, slot_index);
        self.live_count += 1;
        return true;
    }

    /// Removes an exact quad. Slots and posting-list positions remain stable so existing
    /// insertion order is preserved; iterators must not span mutations.
    pub fn remove(self: *Store, quad: rdf.Quad) bool {
        const key = quadKey(quad);
        const slot_index = self.active_quads.get(key) orelse return false;
        _ = self.active_quads.remove(key);
        self.slots.items[slot_index].active = false;
        self.live_count -= 1;
        return true;
    }

    pub fn contains(self: *const Store, quad: rdf.Quad) bool {
        return self.active_quads.contains(quadKey(quad));
    }

    pub fn len(self: *const Store) usize {
        return self.live_count;
    }

    /// Returns an allocation-free iterator. When fields are bound, the shortest
    /// available component posting list drives the scan; results retain insertion order.
    pub fn iterator(self: *const Store, pattern: rdf.QuadPattern) Iterator {
        var candidates: ?[]const usize = null;
        if (pattern.subject) |value| chooseCandidates(&candidates, self.subject_index.get(value));
        if (pattern.predicate) |value| chooseCandidates(&candidates, self.predicate_index.get(value));
        if (pattern.object) |value| chooseCandidates(&candidates, self.object_index.get(value));
        if (pattern.graph_name) |value| chooseCandidates(&candidates, self.graph_index.get(graphKey(value)));
        return .{ .store = self, .pattern = pattern, .candidates = candidates };
    }
};

pub const Iterator = struct {
    store: *const Store,
    pattern: rdf.QuadPattern,
    candidates: ?[]const usize,
    index: usize = 0,

    pub fn next(self: *Iterator) ?rdf.Quad {
        if (self.candidates) |candidates| {
            while (self.index < candidates.len) {
                const slot = self.store.slots.items[candidates[self.index]];
                self.index += 1;
                if (slot.active and self.pattern.matches(slot.quad)) return slot.quad;
            }
            return null;
        }

        while (self.index < self.store.slots.items.len) {
            const slot = self.store.slots.items[self.index];
            self.index += 1;
            if (slot.active and self.pattern.matches(slot.quad)) return slot.quad;
        }
        return null;
    }
};

fn appendPosting(
    comptime Key: type,
    index: *std.AutoHashMapUnmanaged(Key, PostingList),
    allocator: std.mem.Allocator,
    key: Key,
    slot_index: usize,
) std.mem.Allocator.Error!PostingMutation {
    const entry = try index.getOrPut(allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    errdefer if (!entry.found_existing) {
        _ = index.remove(key);
    };
    try entry.value_ptr.append(allocator, slot_index);
    return .{ .created = !entry.found_existing };
}

fn undoPosting(
    comptime Key: type,
    index: *std.AutoHashMapUnmanaged(Key, PostingList),
    allocator: std.mem.Allocator,
    key: Key,
    mutation: PostingMutation,
) void {
    const posting = index.getPtr(key).?;
    _ = posting.pop();
    if (mutation.created) {
        posting.deinit(allocator);
        _ = index.remove(key);
    }
}

fn deinitIndex(
    comptime Key: type,
    index: *std.AutoHashMapUnmanaged(Key, PostingList),
    allocator: std.mem.Allocator,
) void {
    var values = index.valueIterator();
    while (values.next()) |posting| posting.deinit(allocator);
    index.deinit(allocator);
}

fn chooseCandidates(current: *?[]const usize, posting: ?PostingList) void {
    const candidate = if (posting) |value| value.items else &[_]usize{};
    if (current.* == null or candidate.len < current.*.?.len) current.* = candidate;
}

fn quadKey(quad: rdf.Quad) QuadKey {
    return .{
        .subject = @backingInt(quad.subject),
        .predicate = @backingInt(quad.predicate),
        .object = @backingInt(quad.object),
        .graph = graphKey(quad.graph_name),
    };
}

fn graphKey(graph_name: rdf.GraphName) u64 {
    return switch (graph_name) {
        .default => 0,
        .named => |id| @as(u64, @backingInt(id)) + 1,
    };
}

test "store indexes deterministic quad pattern iteration" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const alice = try store.terms.internNamedNode("https://example.com/alice");
    const bob = try store.terms.internNamedNode("https://example.com/bob");
    const knows = try store.terms.internNamedNode("https://example.com/knows");
    const name = try store.terms.internNamedNode("https://example.com/name");
    const alice_name = try store.terms.internSimpleLiteral("Alice");
    const graph = try store.terms.internNamedNode("https://example.com/graph");

    const first = rdf.Quad{ .subject = alice, .predicate = knows, .object = bob };
    const second = rdf.Quad{ .subject = alice, .predicate = name, .object = alice_name };
    const third = rdf.Quad{
        .subject = bob,
        .predicate = knows,
        .object = alice,
        .graph_name = .{ .named = graph },
    };
    try std.testing.expect(try store.add(first));
    try std.testing.expect(try store.add(second));
    try std.testing.expect(try store.add(third));
    try std.testing.expect(!(try store.add(first)));
    try std.testing.expectError(error.InvalidSubject, store.add(.{
        .subject = alice_name,
        .predicate = knows,
        .object = bob,
    }));

    var alice_matches = store.iterator(.{ .subject = alice });
    try std.testing.expectEqual(first, alice_matches.next().?);
    try std.testing.expectEqual(second, alice_matches.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), alice_matches.next());

    var named_matches = store.iterator(.{ .graph_name = .{ .named = graph } });
    try std.testing.expectEqual(third, named_matches.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), named_matches.next());
}

test "store removal and reinsertion retain deterministic live order" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const first_object = try store.terms.internSimpleLiteral("first");
    const second_object = try store.terms.internSimpleLiteral("second");
    const first = rdf.Quad{ .subject = subject, .predicate = predicate, .object = first_object };
    const second = rdf.Quad{ .subject = subject, .predicate = predicate, .object = second_object };
    _ = try store.add(first);
    _ = try store.add(second);

    try std.testing.expect(store.remove(first));
    try std.testing.expect(!store.remove(first));
    try std.testing.expect(!store.contains(first));
    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expect(try store.add(first));

    var all = store.iterator(.{});
    try std.testing.expectEqual(second, all.next().?);
    try std.testing.expectEqual(first, all.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), all.next());
}

fn exerciseStoreAllocations(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const object = try store.terms.internSimpleLiteral("object");
    const graph = try store.terms.internBlankNode("graph");
    _ = try store.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph },
    });
}

test "store insertion handles every allocation failure without partial indexes" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseStoreAllocations,
        .{},
    );
}

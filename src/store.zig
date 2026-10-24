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

pub const Error = rdf.Error || error{
    TransactionActive,
    TransactionClosed,
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
    transaction_active: bool = false,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .terms = .init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        std.debug.assert(!self.transaction_active);
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
    pub fn add(self: *Store, quad: rdf.Quad) Error!bool {
        if (self.transaction_active) return error.TransactionActive;
        return self.addInternal(quad);
    }

    fn addInternal(self: *Store, quad: rdf.Quad) rdf.Error!bool {
        try rdf.validateTriple(&self.terms, .{
            .subject = quad.subject,
            .predicate = quad.predicate,
            .object = quad.object,
        });
        try rdf.validateGraphName(&self.terms, quad.graph_name);

        const key = quadKey(quad);
        if (self.active_quads.contains(key)) return false;

        try self.appendIndexed(quad, key);
        return true;
    }

    fn appendIndexed(
        self: *Store,
        quad: rdf.Quad,
        key: QuadKey,
    ) std.mem.Allocator.Error!void {
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
    }

    /// Removes an exact quad. Slots and posting-list positions remain stable so existing
    /// insertion order is preserved; iterators must not span mutations.
    pub fn remove(self: *Store, quad: rdf.Quad) Error!bool {
        if (self.transaction_active) return error.TransactionActive;
        return self.removeInternal(quad) != null;
    }

    fn removeInternal(self: *Store, quad: rdf.Quad) ?usize {
        const key = quadKey(quad);
        const slot_index = self.active_quads.get(key) orelse return null;
        _ = self.active_quads.remove(key);
        self.slots.items[slot_index].active = false;
        self.live_count -= 1;
        return slot_index;
    }

    pub fn contains(self: *const Store, quad: rdf.Quad) bool {
        return self.active_quads.contains(quadKey(quad));
    }

    pub fn len(self: *const Store) usize {
        return self.live_count;
    }

    /// Returns live and removed slots currently retained by the store.
    pub fn slotCount(self: *const Store) usize {
        return self.slots.items.len;
    }

    pub fn tombstoneCount(self: *const Store) usize {
        return self.slots.items.len - self.live_count;
    }

    /// Rebuilds slots and indexes using only live quads. Failure leaves the original
    /// store unchanged. Live iteration order and term identifiers are preserved.
    pub fn compact(self: *Store) Error!void {
        if (self.transaction_active) return error.TransactionActive;
        if (self.tombstoneCount() == 0) return;

        var rebuilt = Store.init(self.allocator);
        errdefer rebuilt.deinit();
        for (self.slots.items) |slot| {
            if (!slot.active) continue;
            try rebuilt.appendIndexed(slot.quad, quadKey(slot.quad));
        }

        std.mem.swap(std.ArrayList(Slot), &self.slots, &rebuilt.slots);
        std.mem.swap(
            std.AutoHashMapUnmanaged(QuadKey, usize),
            &self.active_quads,
            &rebuilt.active_quads,
        );
        std.mem.swap(TermIndex, &self.subject_index, &rebuilt.subject_index);
        std.mem.swap(TermIndex, &self.predicate_index, &rebuilt.predicate_index);
        std.mem.swap(TermIndex, &self.object_index, &rebuilt.object_index);
        std.mem.swap(GraphIndex, &self.graph_index, &rebuilt.graph_index);
        std.mem.swap(usize, &self.live_count, &rebuilt.live_count);
        rebuilt.deinit();
    }

    /// Begins the store's only active transaction. Tentative changes are visible to
    /// reads through the store and transaction until commit or rollback.
    pub fn beginTransaction(self: *Store) Error!Transaction {
        if (self.transaction_active) return error.TransactionActive;
        self.transaction_active = true;
        return .{ .store = self };
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

const Undo = union(enum) {
    added: rdf.Quad,
    removed: struct {
        quad: rdf.Quad,
        slot_index: usize,
    },
};

pub const Transaction = struct {
    store: *Store,
    undo: std.ArrayList(Undo) = .empty,
    active: bool = true,

    /// Rolls back automatically when an active transaction leaves scope.
    pub fn deinit(self: *Transaction) void {
        if (self.active) self.rollbackInternal();
        self.undo.deinit(self.store.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Transaction, quad: rdf.Quad) Error!bool {
        if (!self.active) return error.TransactionClosed;
        try rdf.validateTriple(&self.store.terms, .{
            .subject = quad.subject,
            .predicate = quad.predicate,
            .object = quad.object,
        });
        try rdf.validateGraphName(&self.store.terms, quad.graph_name);
        if (self.store.contains(quad)) return false;
        try self.undo.ensureUnusedCapacity(self.store.allocator, 1);
        const inserted = try self.store.addInternal(quad);
        std.debug.assert(inserted);
        self.undo.appendAssumeCapacity(.{ .added = quad });
        return true;
    }

    pub fn remove(self: *Transaction, quad: rdf.Quad) Error!bool {
        if (!self.active) return error.TransactionClosed;
        if (!self.store.contains(quad)) return false;
        try self.undo.ensureUnusedCapacity(self.store.allocator, 1);
        const slot_index = self.store.removeInternal(quad).?;
        self.undo.appendAssumeCapacity(.{ .removed = .{
            .quad = quad,
            .slot_index = slot_index,
        } });
        return true;
    }

    pub fn commit(self: *Transaction) Error!void {
        if (!self.active) return error.TransactionClosed;
        self.undo.clearRetainingCapacity();
        self.close();
    }

    pub fn rollback(self: *Transaction) Error!void {
        if (!self.active) return error.TransactionClosed;
        self.rollbackInternal();
    }

    fn rollbackInternal(self: *Transaction) void {
        var index = self.undo.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.undo.items[index]) {
                .added => |quad| _ = self.store.removeInternal(quad),
                .removed => |entry| {
                    const key = quadKey(entry.quad);
                    self.store.active_quads.putAssumeCapacity(key, entry.slot_index);
                    self.store.slots.items[entry.slot_index].active = true;
                    self.store.live_count += 1;
                },
            }
        }
        self.undo.clearRetainingCapacity();
        self.close();
    }

    fn close(self: *Transaction) void {
        self.active = false;
        self.store.transaction_active = false;
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

    try std.testing.expect(try store.remove(first));
    try std.testing.expect(!(try store.remove(first)));
    try std.testing.expect(!store.contains(first));
    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expect(try store.add(first));

    var all = store.iterator(.{});
    try std.testing.expectEqual(second, all.next().?);
    try std.testing.expectEqual(first, all.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), all.next());
}

test "store compaction reclaims tombstones and preserves indexed order" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const first_object = try store.terms.internSimpleLiteral("first");
    const removed_object = try store.terms.internSimpleLiteral("removed");
    const third_object = try store.terms.internSimpleLiteral("third");
    const last_object = try store.terms.internSimpleLiteral("last");
    const first = rdf.Quad{ .subject = subject, .predicate = predicate, .object = first_object };
    const removed = rdf.Quad{ .subject = subject, .predicate = predicate, .object = removed_object };
    const third = rdf.Quad{ .subject = subject, .predicate = predicate, .object = third_object };
    const last = rdf.Quad{ .subject = subject, .predicate = predicate, .object = last_object };
    _ = try store.add(first);
    _ = try store.add(removed);
    _ = try store.add(third);
    try std.testing.expect(try store.remove(removed));
    _ = try store.add(last);
    try std.testing.expectEqual(@as(usize, 4), store.slotCount());
    try std.testing.expectEqual(@as(usize, 1), store.tombstoneCount());

    try store.compact();
    try std.testing.expectEqual(@as(usize, 3), store.slotCount());
    try std.testing.expectEqual(@as(usize, 0), store.tombstoneCount());
    try std.testing.expect(!store.contains(removed));

    var matches = store.iterator(.{ .subject = subject });
    try std.testing.expectEqual(first, matches.next().?);
    try std.testing.expectEqual(third, matches.next().?);
    try std.testing.expectEqual(last, matches.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), matches.next());
}

test "store transaction commit is atomic and excludes direct mutation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const first_object = try store.terms.internSimpleLiteral("first");
    const second_object = try store.terms.internSimpleLiteral("second");
    const first = rdf.Quad{ .subject = subject, .predicate = predicate, .object = first_object };
    const second = rdf.Quad{ .subject = subject, .predicate = predicate, .object = second_object };
    _ = try store.add(first);

    var transaction = try store.beginTransaction();
    defer transaction.deinit();
    try std.testing.expectError(error.TransactionActive, store.beginTransaction());
    try std.testing.expectError(error.TransactionActive, store.add(second));
    try std.testing.expectError(error.TransactionActive, store.remove(first));
    try std.testing.expectError(error.TransactionActive, store.compact());
    try std.testing.expect(try transaction.remove(first));
    try std.testing.expect(try transaction.add(second));
    try std.testing.expect(!store.contains(first));
    try std.testing.expect(store.contains(second));
    try transaction.commit();

    try std.testing.expectError(error.TransactionClosed, transaction.add(first));
    try std.testing.expect(!store.contains(first));
    try std.testing.expect(store.contains(second));
    try std.testing.expectEqual(@as(usize, 1), store.len());
}

test "store transaction rollback restores contents and order without allocating" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const first_object = try store.terms.internSimpleLiteral("first");
    const second_object = try store.terms.internSimpleLiteral("second");
    const temporary_object = try store.terms.internSimpleLiteral("temporary");
    const first = rdf.Quad{ .subject = subject, .predicate = predicate, .object = first_object };
    const second = rdf.Quad{ .subject = subject, .predicate = predicate, .object = second_object };
    const temporary = rdf.Quad{ .subject = subject, .predicate = predicate, .object = temporary_object };
    _ = try store.add(first);
    _ = try store.add(second);

    var transaction = try store.beginTransaction();
    defer transaction.deinit();
    try std.testing.expect(try transaction.remove(first));
    try std.testing.expect(try transaction.add(temporary));
    try transaction.rollback();

    try std.testing.expect(store.contains(first));
    try std.testing.expect(store.contains(second));
    try std.testing.expect(!store.contains(temporary));
    var all = store.iterator(.{});
    try std.testing.expectEqual(first, all.next().?);
    try std.testing.expectEqual(second, all.next().?);
    try std.testing.expectEqual(@as(?rdf.Quad, null), all.next());
}

test "active store transaction rolls back when deinitialized" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const object = try store.terms.internSimpleLiteral("object");
    const quad = rdf.Quad{ .subject = subject, .predicate = predicate, .object = object };
    {
        var transaction = try store.beginTransaction();
        defer transaction.deinit();
        try std.testing.expect(try transaction.add(quad));
    }
    try std.testing.expect(!store.contains(quad));
    try std.testing.expectEqual(@as(usize, 0), store.len());
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

fn exerciseTransactionAllocations(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const object = try store.terms.internSimpleLiteral("object");
    const quad = rdf.Quad{ .subject = subject, .predicate = predicate, .object = object };
    var transaction = try store.beginTransaction();
    defer transaction.deinit();
    _ = try transaction.add(quad);
    try transaction.commit();
}

test "store transaction handles every allocation failure atomically" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTransactionAllocations,
        .{},
    );
}

fn exerciseCompactionAllocations(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();

    const subject = try store.terms.internNamedNode("https://example.com/subject");
    const predicate = try store.terms.internNamedNode("https://example.com/predicate");
    const first_object = try store.terms.internSimpleLiteral("first");
    const second_object = try store.terms.internSimpleLiteral("second");
    const first = rdf.Quad{ .subject = subject, .predicate = predicate, .object = first_object };
    const second = rdf.Quad{ .subject = subject, .predicate = predicate, .object = second_object };
    _ = try store.add(first);
    _ = try store.add(second);
    _ = try store.remove(first);
    try store.compact();
}

test "store compaction handles every allocation failure atomically" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactionAllocations,
        .{},
    );
}

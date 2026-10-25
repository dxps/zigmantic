//! SPARQL solution mappings and basic graph-pattern evaluation.

const std = @import("std");
const rdf = @import("rdf.zig");
const sparql = @import("sparql.zig");
const store_mod = @import("store.zig");

pub const EvaluationError = std.mem.Allocator.Error || error{
    InvalidAlgebra,
    UnsupportedGraphPattern,
};

pub const SolutionBinding = struct {
    variable: []const u8,
    value: rdf.TermId,
};

pub const SolutionMapping = struct {
    bindings: []SolutionBinding,

    pub fn get(self: SolutionMapping, variable: []const u8) ?rdf.TermId {
        for (self.bindings) |binding| {
            if (std.mem.eql(u8, binding.variable, variable)) return binding.value;
        }
        return null;
    }
};

/// Allocator-owned multiset of solution mappings. Variable names borrow the parsed
/// query, and term identifiers belong to the evaluated store's term pool.
pub const SolutionSequence = struct {
    allocator: std.mem.Allocator,
    mappings: []SolutionMapping,

    pub fn deinit(self: *SolutionSequence) void {
        for (self.mappings) |mapping| self.allocator.free(mapping.bindings);
        self.allocator.free(self.mappings);
        self.* = undefined;
    }
};

pub const ExpressionFault = error{
    UnboundVariable,
    TypeError,
    UnknownTerm,
    UnsupportedExpression,
};

pub const ExpressionResult = union(enum) {
    value: rdf.TermId,
    fault: ExpressionFault,
};

/// Owns RDF terms produced while evaluating expressions. Source bindings contain IDs
/// from `source_terms`; successful expression results contain IDs from `terms`.
pub const ExpressionEvaluator = struct {
    allocator: std.mem.Allocator,
    query: *const sparql.Query,
    source_terms: *const rdf.TermPool,
    terms: rdf.TermPool,

    pub fn init(
        allocator: std.mem.Allocator,
        query: *const sparql.Query,
        source_terms: *const rdf.TermPool,
    ) ExpressionEvaluator {
        return .{
            .allocator = allocator,
            .query = query,
            .source_terms = source_terms,
            .terms = .init(allocator),
        };
    }

    pub fn deinit(self: *ExpressionEvaluator) void {
        self.terms.deinit();
        self.* = undefined;
    }

    /// Evaluates the RDF-term/variable foundation plus BOUND and logical negation.
    /// Other operators and functions return `UnsupportedExpression` in this phase.
    pub fn evaluate(
        self: *ExpressionEvaluator,
        expression_id: sparql.ExpressionId,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const expression = self.query.expression(expression_id) orelse
            return .{ .fault = error.UnsupportedExpression };
        return switch (expression) {
            .variable => |variable| if (mapping.get(variable)) |value|
                self.copySourceTerm(value)
            else
                .{ .fault = error.UnboundVariable },
            .iri => |iri| self.internNamedNode(iri),
            .literal => |literal| self.internLiteral(literal),
            .unary => |unary| if (unary.operator == .logical_not)
                self.evaluateLogicalNot(unary.operand, mapping)
            else
                .{ .fault = error.UnsupportedExpression },
            .call => |call| if (std.mem.eql(u8, call.function, "bound"))
                self.evaluateBound(call, mapping)
            else
                .{ .fault = error.UnsupportedExpression },
            .wildcard, .binary, .membership, .exists => .{
                .fault = error.UnsupportedExpression,
            },
        };
    }

    /// Implements SPARQL effective boolean value for boolean, numeric, string, and
    /// language-tagged literals. Other RDF terms and invalid lexical forms are errors.
    pub fn effectiveBooleanValue(self: *const ExpressionEvaluator, value: rdf.TermId) ExpressionFault!bool {
        const view = self.terms.view(value) orelse return error.UnknownTerm;
        const literal = switch (view) {
            .literal => |item| item,
            else => return error.TypeError,
        };
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_namespace ++ "boolean")) {
            if (std.mem.eql(u8, literal.lexical_form, "true") or
                std.mem.eql(u8, literal.lexical_form, "1")) return true;
            if (std.mem.eql(u8, literal.lexical_form, "false") or
                std.mem.eql(u8, literal.lexical_form, "0")) return false;
            return error.TypeError;
        }
        if (isEffectiveBooleanNumeric(literal.datatype)) {
            const number = std.fmt.parseFloat(f64, literal.lexical_form) catch
                return error.TypeError;
            return number != 0 and !std.math.isNan(number);
        }
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_string) or
            std.mem.eql(u8, literal.datatype, rdf.rdf_lang_string))
        {
            return literal.lexical_form.len != 0;
        }
        return error.TypeError;
    }

    fn copySourceTerm(
        self: *ExpressionEvaluator,
        value: rdf.TermId,
    ) std.mem.Allocator.Error!ExpressionResult {
        const view = self.source_terms.view(value) orelse
            return .{ .fault = error.UnknownTerm };
        const copied = self.terms.internView(view) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .{ .fault = error.TypeError },
        };
        return .{ .value = copied };
    }

    fn internNamedNode(
        self: *ExpressionEvaluator,
        iri: []const u8,
    ) std.mem.Allocator.Error!ExpressionResult {
        const value = self.terms.internNamedNode(iri) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .{ .fault = error.TypeError },
        };
        return .{ .value = value };
    }

    fn internLiteral(
        self: *ExpressionEvaluator,
        literal: sparql.Literal,
    ) std.mem.Allocator.Error!ExpressionResult {
        const value = if (literal.language) |language|
            self.terms.internLanguageLiteral(literal.lexical_form, language)
        else
            self.terms.internTypedLiteral(literal.lexical_form, literal.datatype);
        const id = value catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .{ .fault = error.TypeError },
        };
        return .{ .value = id };
    }

    fn internBoolean(
        self: *ExpressionEvaluator,
        value: bool,
    ) std.mem.Allocator.Error!ExpressionResult {
        const id = self.terms.internTypedLiteral(
            if (value) "true" else "false",
            rdf.xsd_namespace ++ "boolean",
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
        return .{ .value = id };
    }

    fn evaluateLogicalNot(
        self: *ExpressionEvaluator,
        operand: sparql.ExpressionId,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const result = try self.evaluate(operand, mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => return result,
        };
        const boolean = self.effectiveBooleanValue(value) catch |fault|
            return .{ .fault = fault };
        return self.internBoolean(!boolean);
    }

    fn evaluateBound(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 1) return .{ .fault = error.UnsupportedExpression };
        const expression = self.query.expression(arguments[0]) orelse
            return .{ .fault = error.UnsupportedExpression };
        const variable = switch (expression) {
            .variable => |value| value,
            else => return .{ .fault = error.UnsupportedExpression },
        };
        return self.internBoolean(mapping.get(variable) != null);
    }
};

const BindingKey = union(enum) {
    variable: []const u8,
    labeled_blank_node: []const u8,
    anonymous_blank_node: usize,
};

const InternalBinding = struct {
    key: BindingKey,
    value: rdf.TermId,
};

const InternalMapping = struct {
    bindings: std.ArrayList(InternalBinding) = .empty,

    fn deinit(self: *InternalMapping, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }

    fn clone(self: InternalMapping, allocator: std.mem.Allocator) EvaluationError!InternalMapping {
        var copy: InternalMapping = .{};
        errdefer copy.deinit(allocator);
        try copy.bindings.appendSlice(allocator, self.bindings.items);
        return copy;
    }

    fn get(self: InternalMapping, key: BindingKey) ?rdf.TermId {
        for (self.bindings.items) |binding| {
            if (bindingKeyEql(binding.key, key)) return binding.value;
        }
        return null;
    }

    fn bind(
        self: *InternalMapping,
        allocator: std.mem.Allocator,
        key: BindingKey,
        value: rdf.TermId,
    ) EvaluationError!bool {
        if (self.get(key)) |existing| return existing == value;
        try self.bindings.append(allocator, .{ .key = key, .value = value });
        return true;
    }
};

const PatternComponent = union(enum) {
    key: BindingKey,
    constant: rdf.TermId,
    absent,
};

const CompiledTriple = struct {
    subject: PatternComponent,
    predicate: PatternComponent,
    object: PatternComponent,

    fn hasAbsentConstant(self: CompiledTriple) bool {
        return self.subject == .absent or self.predicate == .absent or self.object == .absent;
    }
};

/// Evaluates a root group containing only ordinary triple patterns against the store's
/// default graph. The result preserves bag multiplicity and deterministic join order.
pub fn evaluateBasicGraphPattern(
    allocator: std.mem.Allocator,
    query: *const sparql.Query,
    dataset: *const store_mod.Store,
) EvaluationError!SolutionSequence {
    if (query.datasetClauses().len != 0) return error.UnsupportedGraphPattern;
    const group_id = query.root_group orelse return error.InvalidAlgebra;
    const elements = query.groupElements(group_id) orelse return error.InvalidAlgebra;

    var current: std.ArrayList(InternalMapping) = .empty;
    defer deinitInternalMappings(allocator, &current);
    try current.append(allocator, .{});

    for (elements) |element| {
        const triple_index = switch (element) {
            .triple => |value| value,
            else => return error.UnsupportedGraphPattern,
        };
        if (triple_index >= query.patterns().len) return error.InvalidAlgebra;
        const triple = try compileTriple(query.patterns()[triple_index], dataset);
        const next = try joinTriple(allocator, current.items, triple, dataset);
        deinitInternalMappings(allocator, &current);
        current = next;
    }

    var mappings: std.ArrayList(SolutionMapping) = .empty;
    errdefer deinitSolutionMappings(allocator, &mappings);
    for (current.items) |mapping| {
        var count: usize = 0;
        for (mapping.bindings.items) |binding| {
            if (binding.key == .variable) count += 1;
        }
        const bindings = try allocator.alloc(SolutionBinding, count);
        errdefer allocator.free(bindings);
        var index: usize = 0;
        for (mapping.bindings.items) |binding| switch (binding.key) {
            .variable => |variable| {
                bindings[index] = .{ .variable = variable, .value = binding.value };
                index += 1;
            },
            else => {},
        };
        try mappings.append(allocator, .{ .bindings = bindings });
    }

    return .{
        .allocator = allocator,
        .mappings = try mappings.toOwnedSlice(allocator),
    };
}

fn joinTriple(
    allocator: std.mem.Allocator,
    input: []const InternalMapping,
    triple: CompiledTriple,
    dataset: *const store_mod.Store,
) EvaluationError!std.ArrayList(InternalMapping) {
    var output: std.ArrayList(InternalMapping) = .empty;
    errdefer deinitInternalMappings(allocator, &output);
    if (triple.hasAbsentConstant()) return output;

    for (input) |mapping| {
        var iterator = dataset.iterator(.{
            .subject = boundValue(triple.subject, mapping),
            .predicate = boundValue(triple.predicate, mapping),
            .object = boundValue(triple.object, mapping),
            .graph_name = .default,
        });
        while (iterator.next()) |quad| {
            var extended = try mapping.clone(allocator);
            errdefer extended.deinit(allocator);
            if (!try bindComponent(allocator, &extended, triple.subject, quad.subject) or
                !try bindComponent(allocator, &extended, triple.predicate, quad.predicate) or
                !try bindComponent(allocator, &extended, triple.object, quad.object))
            {
                extended.deinit(allocator);
                continue;
            }
            try output.append(allocator, extended);
        }
    }
    return output;
}

fn compileTriple(
    triple: sparql.TriplePattern,
    dataset: *const store_mod.Store,
) EvaluationError!CompiledTriple {
    return .{
        .subject = try compileTerm(triple.subject, dataset),
        .predicate = try compileTerm(triple.predicate, dataset),
        .object = try compileTerm(triple.object, dataset),
    };
}

fn compileTerm(
    term: sparql.PatternTerm,
    dataset: *const store_mod.Store,
) EvaluationError!PatternComponent {
    return switch (term) {
        .variable => |name| .{ .key = .{ .variable = name } },
        .blank_node => |blank_node| .{ .key = switch (blank_node) {
            .labeled => |label| .{ .labeled_blank_node = label },
            .anonymous => |id| .{ .anonymous_blank_node = id },
        } },
        .iri => |iri| if (findNamedNode(&dataset.terms, iri)) |id|
            .{ .constant = id }
        else
            .absent,
        .literal => |literal| if (findLiteral(&dataset.terms, literal)) |id|
            .{ .constant = id }
        else
            .absent,
        .path => error.UnsupportedGraphPattern,
    };
}

fn findNamedNode(terms: *const rdf.TermPool, iri: []const u8) ?rdf.TermId {
    for (0..terms.count()) |index| {
        const id: rdf.TermId = @fromBackingInt(@intCast(index));
        const view = terms.view(id) orelse continue;
        switch (view) {
            .named_node => |value| if (std.mem.eql(u8, value, iri)) return id,
            else => {},
        }
    }
    return null;
}

fn findLiteral(terms: *const rdf.TermPool, expected: sparql.Literal) ?rdf.TermId {
    for (0..terms.count()) |index| {
        const id: rdf.TermId = @fromBackingInt(@intCast(index));
        const view = terms.view(id) orelse continue;
        switch (view) {
            .literal => |literal| if (std.mem.eql(u8, literal.lexical_form, expected.lexical_form) and
                std.mem.eql(u8, literal.datatype, expected.datatype) and
                optionalStringEql(literal.language, expected.language)) return id,
            else => {},
        }
    }
    return null;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn isEffectiveBooleanNumeric(datatype: []const u8) bool {
    return std.mem.eql(u8, datatype, rdf.xsd_integer) or
        std.mem.eql(u8, datatype, rdf.xsd_int) or
        std.mem.eql(u8, datatype, rdf.xsd_decimal) or
        std.mem.eql(u8, datatype, rdf.xsd_float) or
        std.mem.eql(u8, datatype, rdf.xsd_double);
}

fn boundValue(component: PatternComponent, mapping: InternalMapping) ?rdf.TermId {
    return switch (component) {
        .key => |key| mapping.get(key),
        .constant => |value| value,
        .absent => null,
    };
}

fn bindComponent(
    allocator: std.mem.Allocator,
    mapping: *InternalMapping,
    component: PatternComponent,
    value: rdf.TermId,
) EvaluationError!bool {
    return switch (component) {
        .key => |key| mapping.bind(allocator, key, value),
        .constant => |expected| expected == value,
        .absent => false,
    };
}

fn bindingKeyEql(left: BindingKey, right: BindingKey) bool {
    return switch (left) {
        .variable => |value| switch (right) {
            .variable => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .labeled_blank_node => |value| switch (right) {
            .labeled_blank_node => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .anonymous_blank_node => |value| switch (right) {
            .anonymous_blank_node => |other| value == other,
            else => false,
        },
    };
}

fn deinitInternalMappings(
    allocator: std.mem.Allocator,
    mappings: *std.ArrayList(InternalMapping),
) void {
    for (mappings.items) |*mapping| mapping.deinit(allocator);
    mappings.deinit(allocator);
    mappings.* = .empty;
}

fn deinitSolutionMappings(
    allocator: std.mem.Allocator,
    mappings: *std.ArrayList(SolutionMapping),
) void {
    for (mappings.items) |mapping| allocator.free(mapping.bindings);
    mappings.deinit(allocator);
}

test "evaluates joined default-graph triple patterns" {
    var dataset = store_mod.Store.init(std.testing.allocator);
    defer dataset.deinit();

    const alice = try dataset.terms.internNamedNode("https://example.com/alice");
    const bob = try dataset.terms.internNamedNode("https://example.com/bob");
    const carol = try dataset.terms.internNamedNode("https://example.com/carol");
    const knows = try dataset.terms.internNamedNode("https://example.com/knows");
    const name = try dataset.terms.internNamedNode("https://example.com/name");
    const bob_name = try dataset.terms.internSimpleLiteral("Bob");
    const carol_name = try dataset.terms.internSimpleLiteral("Carol");
    const graph = try dataset.terms.internNamedNode("https://example.com/graph");
    _ = try dataset.add(.{ .subject = alice, .predicate = knows, .object = bob });
    _ = try dataset.add(.{ .subject = alice, .predicate = knows, .object = carol });
    _ = try dataset.add(.{ .subject = bob, .predicate = name, .object = bob_name });
    _ = try dataset.add(.{ .subject = carol, .predicate = name, .object = carol_name });
    _ = try dataset.add(.{
        .subject = bob,
        .predicate = name,
        .object = carol_name,
        .graph_name = .{ .named = graph },
    });

    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT * { <https://example.com/alice> <https://example.com/knows> ?friend . " ++
            "?friend <https://example.com/name> ?name }",
    );
    defer query.deinit();
    var solutions = try evaluateBasicGraphPattern(std.testing.allocator, &query, &dataset);
    defer solutions.deinit();

    try std.testing.expectEqual(@as(usize, 2), solutions.mappings.len);
    try std.testing.expectEqual(bob, solutions.mappings[0].get("friend").?);
    try std.testing.expectEqual(bob_name, solutions.mappings[0].get("name").?);
    try std.testing.expectEqual(carol, solutions.mappings[1].get("friend").?);
    try std.testing.expectEqual(carol_name, solutions.mappings[1].get("name").?);
}

test "preserves repeated variables and hides query blank-node bindings" {
    var dataset = store_mod.Store.init(std.testing.allocator);
    defer dataset.deinit();
    const first = try dataset.terms.internNamedNode("urn:first");
    const second = try dataset.terms.internNamedNode("urn:second");
    const same = try dataset.terms.internNamedNode("urn:same");
    _ = try dataset.add(.{ .subject = first, .predicate = same, .object = first });
    _ = try dataset.add(.{ .subject = second, .predicate = same, .object = first });

    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT ?value { _:source <urn:same> ?value . ?value <urn:same> ?value }",
    );
    defer query.deinit();
    var solutions = try evaluateBasicGraphPattern(std.testing.allocator, &query, &dataset);
    defer solutions.deinit();

    try std.testing.expectEqual(@as(usize, 2), solutions.mappings.len);
    for (solutions.mappings) |mapping| {
        try std.testing.expectEqual(@as(usize, 1), mapping.bindings.len);
        try std.testing.expectEqual(first, mapping.get("value").?);
    }
}

test "evaluates empty and unmatched basic graph patterns" {
    var dataset = store_mod.Store.init(std.testing.allocator);
    defer dataset.deinit();

    var empty_query = try sparql.parseQuery(std.testing.allocator, "SELECT * {}");
    defer empty_query.deinit();
    var identity = try evaluateBasicGraphPattern(std.testing.allocator, &empty_query, &dataset);
    defer identity.deinit();
    try std.testing.expectEqual(@as(usize, 1), identity.mappings.len);
    try std.testing.expectEqual(@as(usize, 0), identity.mappings[0].bindings.len);

    var unmatched_query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT * { ?s <urn:absent> ?o }",
    );
    defer unmatched_query.deinit();
    var unmatched = try evaluateBasicGraphPattern(
        std.testing.allocator,
        &unmatched_query,
        &dataset,
    );
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 0), unmatched.mappings.len);
}

test "rejects graph operators and property paths in the BGP evaluator" {
    var dataset = store_mod.Store.init(std.testing.allocator);
    defer dataset.deinit();

    var optional_query = try sparql.parseQuery(std.testing.allocator, "SELECT * { OPTIONAL {} }");
    defer optional_query.deinit();
    try std.testing.expectError(
        error.UnsupportedGraphPattern,
        evaluateBasicGraphPattern(std.testing.allocator, &optional_query, &dataset),
    );

    var path_query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT * { ?s <urn:left>/<urn:right> ?o }",
    );
    defer path_query.deinit();
    try std.testing.expectError(
        error.UnsupportedGraphPattern,
        evaluateBasicGraphPattern(std.testing.allocator, &path_query, &dataset),
    );

    var dataset_query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT * FROM <urn:graph> { ?s ?p ?o }",
    );
    defer dataset_query.deinit();
    try std.testing.expectError(
        error.UnsupportedGraphPattern,
        evaluateBasicGraphPattern(std.testing.allocator, &dataset_query, &dataset),
    );
}

test "evaluates variables and RDF constants into an owned term scope" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const source_value = try source.internLanguageLiteral("hello", "EN");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (?value AS ?copy) (<urn:constant> AS ?iri) ('text' AS ?text) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "value", .value = source_value }};
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();

    const projection = query.projection().items;
    const copied = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    const iri = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    const text = (try evaluator.evaluate(projection[2].expression.expression, mapping)).value;
    const copied_view = evaluator.terms.view(copied).?.literal;
    try std.testing.expectEqualStrings("hello", copied_view.lexical_form);
    try std.testing.expectEqualStrings("en", copied_view.language.?);
    try std.testing.expectEqualStrings("urn:constant", evaluator.terms.view(iri).?.named_node);
    try std.testing.expectEqualStrings("text", evaluator.terms.view(text).?.literal.lexical_form);
    try std.testing.expectEqual(@as(usize, 1), source.count());
}

test "computes SPARQL effective boolean values" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    var query = try sparql.parseQuery(std.testing.allocator, "SELECT * {}");
    defer query.deinit();
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();

    const true_value = try evaluator.terms.internTypedLiteral("1", rdf.xsd_namespace ++ "boolean");
    const false_value = try evaluator.terms.internTypedLiteral("false", rdf.xsd_namespace ++ "boolean");
    const zero = try evaluator.terms.internTypedLiteral("0", rdf.xsd_integer);
    const nonzero = try evaluator.terms.internTypedLiteral("-2.5", rdf.xsd_decimal);
    const empty = try evaluator.terms.internSimpleLiteral("");
    const language = try evaluator.terms.internLanguageLiteral("salut", "ro");
    const iri = try evaluator.terms.internNamedNode("urn:value");

    try std.testing.expect(try evaluator.effectiveBooleanValue(true_value));
    try std.testing.expect(!try evaluator.effectiveBooleanValue(false_value));
    try std.testing.expect(!try evaluator.effectiveBooleanValue(zero));
    try std.testing.expect(try evaluator.effectiveBooleanValue(nonzero));
    try std.testing.expect(!try evaluator.effectiveBooleanValue(empty));
    try std.testing.expect(try evaluator.effectiveBooleanValue(language));
    try std.testing.expectError(error.TypeError, evaluator.effectiveBooleanValue(iri));
    const unknown: rdf.TermId = @fromBackingInt(999);
    try std.testing.expectError(error.UnknownTerm, evaluator.effectiveBooleanValue(unknown));
}

test "represents expression faults and evaluates logical not and BOUND" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const false_value = try source.internTypedLiteral("false", rdf.xsd_namespace ++ "boolean");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (!?flag AS ?not) (BOUND(?missing) AS ?bound) (?missing AS ?copy) " ++
            "(?flag + 1 AS ?unsupported) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "flag", .value = false_value }};
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    const negated = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    try std.testing.expect(try evaluator.effectiveBooleanValue(negated));
    const bound = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    try std.testing.expect(!try evaluator.effectiveBooleanValue(bound));
    try std.testing.expectEqual(
        error.UnboundVariable,
        (try evaluator.evaluate(projection[2].expression.expression, mapping)).fault,
    );
    try std.testing.expectEqual(
        error.UnsupportedExpression,
        (try evaluator.evaluate(projection[3].expression.expression, mapping)).fault,
    );
}

test "expression evaluation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectExpressionEvaluationSucceeds,
        .{},
    );
}

test "BGP evaluation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectEvaluationSucceeds, .{});
}

fn expectEvaluationSucceeds(allocator: std.mem.Allocator) !void {
    var dataset = store_mod.Store.init(allocator);
    defer dataset.deinit();
    const subject = try dataset.terms.internNamedNode("urn:subject");
    const predicate = try dataset.terms.internNamedNode("urn:predicate");
    const object = try dataset.terms.internSimpleLiteral("object");
    _ = try dataset.add(.{ .subject = subject, .predicate = predicate, .object = object });

    var query = try sparql.parseQuery(allocator, "SELECT * { ?s <urn:predicate> ?o }");
    defer query.deinit();
    var solutions = try evaluateBasicGraphPattern(allocator, &query, &dataset);
    defer solutions.deinit();
    try std.testing.expectEqual(@as(usize, 1), solutions.mappings.len);
}

fn expectExpressionEvaluationSucceeds(allocator: std.mem.Allocator) !void {
    var source = rdf.TermPool.init(allocator);
    defer source.deinit();
    const value = try source.internSimpleLiteral("value");
    var query = try sparql.parseQuery(allocator, "SELECT (?input AS ?output) {}");
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "input", .value = value }};
    var evaluator = ExpressionEvaluator.init(allocator, &query, &source);
    defer evaluator.deinit();
    const expression_id = query.projection().items[0].expression.expression;
    const result = try evaluator.evaluate(expression_id, .{ .bindings = bindings[0..] });
    try std.testing.expect(result == .value);
}

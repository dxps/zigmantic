//! SPARQL solution mappings and basic graph-pattern evaluation.

const std = @import("std");
const iri_mod = @import("iri.zig");
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

    /// Evaluates RDF terms, numeric and logical operators, comparisons, membership,
    /// BOUND, and logical negation. Other functions remain unsupported in this phase.
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
            .unary => |unary| self.evaluateUnary(unary, mapping),
            .binary => |binary| self.evaluateBinary(binary, mapping),
            .membership => |membership| self.evaluateMembership(membership, mapping),
            .call => |call| self.evaluateCall(call, mapping),
            .wildcard, .exists => .{
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
            const number = numericAsF64(try self.numericValue(value));
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

    fn internInteger(
        self: *ExpressionEvaluator,
        value: i128,
    ) std.mem.Allocator.Error!ExpressionResult {
        const lexical = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        defer self.allocator.free(lexical);
        return self.internComputedLiteral(lexical, rdf.xsd_integer);
    }

    fn internFloat(
        self: *ExpressionEvaluator,
        value: f64,
        datatype: []const u8,
    ) std.mem.Allocator.Error!ExpressionResult {
        if (std.math.isNan(value)) return self.internComputedLiteral("NaN", datatype);
        if (std.math.isInf(value)) {
            return self.internComputedLiteral(if (value < 0) "-INF" else "INF", datatype);
        }
        const lexical = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        defer self.allocator.free(lexical);
        return self.internComputedLiteral(lexical, datatype);
    }

    fn internComputedLiteral(
        self: *ExpressionEvaluator,
        lexical: []const u8,
        datatype: []const u8,
    ) std.mem.Allocator.Error!ExpressionResult {
        const id = self.terms.internTypedLiteral(lexical, datatype) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
        return .{ .value = id };
    }

    fn evaluateUnary(
        self: *ExpressionEvaluator,
        unary: sparql.UnaryExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        if (unary.operator == .logical_not) return self.evaluateLogicalNot(unary.operand, mapping);
        const result = try self.evaluate(unary.operand, mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => return result,
        };
        const numeric = self.numericValue(value) catch |fault| return .{ .fault = fault };
        return switch (unary.operator) {
            .plus => result,
            .minus => switch (numeric) {
                .integer => |integer| minus: {
                    const negated = @subWithOverflow(@as(i128, 0), integer);
                    if (negated[1] != 0) break :minus .{ .fault = error.TypeError };
                    break :minus self.internInteger(negated[0]);
                },
                .decimal => |number| self.internFloat(-number, rdf.xsd_decimal),
                .float32 => |number| self.internFloat(-number, rdf.xsd_float),
                .double => |number| self.internFloat(-number, rdf.xsd_double),
            },
            .logical_not => unreachable,
        };
    }

    fn evaluateBinary(
        self: *ExpressionEvaluator,
        binary: sparql.BinaryExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        return switch (binary.operator) {
            .logical_or, .logical_and => self.evaluateLogical(binary, mapping),
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => self.evaluateComparison(binary, mapping),
            .add, .subtract, .multiply, .divide => self.evaluateArithmetic(binary, mapping),
        };
    }

    fn evaluateArithmetic(
        self: *ExpressionEvaluator,
        binary: sparql.BinaryExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const left_result = try self.evaluate(binary.left, mapping);
        const left_id = switch (left_result) {
            .value => |value| value,
            .fault => return left_result,
        };
        const right_result = try self.evaluate(binary.right, mapping);
        const right_id = switch (right_result) {
            .value => |value| value,
            .fault => return right_result,
        };
        const left = self.numericValue(left_id) catch |fault| return .{ .fault = fault };
        const right = self.numericValue(right_id) catch |fault| return .{ .fault = fault };
        return self.applyArithmetic(binary.operator, left, right);
    }

    fn applyArithmetic(
        self: *ExpressionEvaluator,
        operator: sparql.BinaryOperator,
        left: NumericValue,
        right: NumericValue,
    ) std.mem.Allocator.Error!ExpressionResult {
        if (left == .integer and right == .integer and operator != .divide) {
            const pair = switch (operator) {
                .add => @addWithOverflow(left.integer, right.integer),
                .subtract => @subWithOverflow(left.integer, right.integer),
                .multiply => @mulWithOverflow(left.integer, right.integer),
                else => unreachable,
            };
            if (pair[1] != 0) return .{ .fault = error.TypeError };
            return self.internInteger(pair[0]);
        }

        const left_number = numericAsF64(left);
        const right_number = numericAsF64(right);
        if (operator == .divide and right_number == 0) return .{ .fault = error.TypeError };
        const value = switch (operator) {
            .add => left_number + right_number,
            .subtract => left_number - right_number,
            .multiply => left_number * right_number,
            .divide => left_number / right_number,
            else => unreachable,
        };
        const datatype = promotedNumericDatatype(left, right, operator == .divide);
        const promoted_value = if (std.mem.eql(u8, datatype, rdf.xsd_float))
            @as(f64, @floatCast(@as(f32, @floatCast(value))))
        else
            value;
        return self.internFloat(promoted_value, datatype);
    }

    fn evaluateComparison(
        self: *ExpressionEvaluator,
        binary: sparql.BinaryExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const left_result = try self.evaluate(binary.left, mapping);
        const left = switch (left_result) {
            .value => |value| value,
            .fault => return left_result,
        };
        const right_result = try self.evaluate(binary.right, mapping);
        const right = switch (right_result) {
            .value => |value| value,
            .fault => return right_result,
        };
        const compared = self.compareValues(left, right, binary.operator) catch |fault|
            return .{ .fault = fault };
        return self.internBoolean(compared);
    }

    fn evaluateLogical(
        self: *ExpressionEvaluator,
        binary: sparql.BinaryExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const left = try self.evaluateBooleanOperand(binary.left, mapping);
        if (binary.operator == .logical_or and left == .value and left.value) {
            return self.internBoolean(true);
        }
        if (binary.operator == .logical_and and left == .value and !left.value) {
            return self.internBoolean(false);
        }
        const right = try self.evaluateBooleanOperand(binary.right, mapping);
        return switch (binary.operator) {
            .logical_or => if (right == .value and right.value)
                self.internBoolean(true)
            else if (left == .fault)
                .{ .fault = left.fault }
            else if (right == .fault)
                .{ .fault = right.fault }
            else
                self.internBoolean(false),
            .logical_and => if (right == .value and !right.value)
                self.internBoolean(false)
            else if (left == .fault)
                .{ .fault = left.fault }
            else if (right == .fault)
                .{ .fault = right.fault }
            else
                self.internBoolean(true),
            else => unreachable,
        };
    }

    fn evaluateBooleanOperand(
        self: *ExpressionEvaluator,
        expression_id: sparql.ExpressionId,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!BooleanResult {
        const result = try self.evaluate(expression_id, mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => |fault| return .{ .fault = fault },
        };
        return .{ .value = self.effectiveBooleanValue(value) catch |fault|
            return .{ .fault = fault } };
    }

    fn evaluateMembership(
        self: *ExpressionEvaluator,
        membership: sparql.MembershipExpression,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const operand_result = try self.evaluate(membership.operand, mapping);
        const operand = switch (operand_result) {
            .value => |value| value,
            .fault => return operand_result,
        };
        const arguments = self.query.expressionArguments(membership.values) orelse
            return .{ .fault = error.UnsupportedExpression };
        var remembered_fault: ?ExpressionFault = null;
        for (arguments) |argument| {
            const candidate_result = try self.evaluate(argument, mapping);
            const candidate = switch (candidate_result) {
                .value => |value| value,
                .fault => |fault| {
                    if (remembered_fault == null) remembered_fault = fault;
                    continue;
                },
            };
            const equal = self.compareValues(operand, candidate, .equal) catch |fault| {
                if (remembered_fault == null) remembered_fault = fault;
                continue;
            };
            if (equal) return self.internBoolean(!membership.negated);
        }
        if (remembered_fault) |fault| return .{ .fault = fault };
        return self.internBoolean(membership.negated);
    }

    fn numericValue(self: *const ExpressionEvaluator, value: rdf.TermId) ExpressionFault!NumericValue {
        const view = self.terms.view(value) orelse return error.UnknownTerm;
        const literal = switch (view) {
            .literal => |item| item,
            else => return error.TypeError,
        };
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_integer) or
            std.mem.eql(u8, literal.datatype, rdf.xsd_int))
        {
            return .{ .integer = std.fmt.parseInt(i128, literal.lexical_form, 10) catch
                return error.TypeError };
        }
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_decimal)) {
            if (!isDecimalLexical(literal.lexical_form)) return error.TypeError;
            return .{ .decimal = std.fmt.parseFloat(f64, literal.lexical_form) catch
                return error.TypeError };
        }
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_float)) {
            const number = parseNumericFloat(literal.lexical_form) orelse return error.TypeError;
            return .{ .float32 = @floatCast(number) };
        }
        if (std.mem.eql(u8, literal.datatype, rdf.xsd_double)) {
            return .{ .double = parseNumericFloat(literal.lexical_form) orelse
                return error.TypeError };
        }
        return error.TypeError;
    }

    fn compareValues(
        self: *const ExpressionEvaluator,
        left_id: rdf.TermId,
        right_id: rdf.TermId,
        operator: sparql.BinaryOperator,
    ) ExpressionFault!bool {
        const left_view = self.terms.view(left_id) orelse return error.UnknownTerm;
        const right_view = self.terms.view(right_id) orelse return error.UnknownTerm;

        const left_is_numeric = termViewIsNumeric(left_view);
        const right_is_numeric = termViewIsNumeric(right_view);
        if (left_is_numeric or right_is_numeric) {
            if (!left_is_numeric or !right_is_numeric) return error.TypeError;
            return compareNumeric(
                try self.numericValue(left_id),
                try self.numericValue(right_id),
                operator,
            );
        }

        return switch (left_view) {
            .named_node => |left| switch (right_view) {
                .named_node => |right| compareEqualityOnly(std.mem.eql(u8, left, right), operator),
                else => compareEqualityOnly(false, operator),
            },
            .blank_node => |left| switch (right_view) {
                .blank_node => |right| compareEqualityOnly(std.mem.eql(u8, left, right), operator),
                else => compareEqualityOnly(false, operator),
            },
            .literal => |left| switch (right_view) {
                .literal => |right| compareLiterals(left, right, operator),
                else => compareEqualityOnly(false, operator),
            },
        };
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

    fn evaluateCall(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        if (std.mem.eql(u8, call.function, "bound")) return self.evaluateBound(call, mapping);
        if (std.mem.eql(u8, call.function, "str") or
            std.mem.eql(u8, call.function, "lang") or
            std.mem.eql(u8, call.function, "datatype") or
            std.mem.eql(u8, call.function, "iri") or
            std.mem.eql(u8, call.function, "uri") or
            std.mem.eql(u8, call.function, "abs") or
            std.mem.eql(u8, call.function, "ceil") or
            std.mem.eql(u8, call.function, "floor") or
            std.mem.eql(u8, call.function, "round") or
            std.mem.eql(u8, call.function, "isiri") or
            std.mem.eql(u8, call.function, "isuri") or
            std.mem.eql(u8, call.function, "isblank") or
            std.mem.eql(u8, call.function, "isliteral") or
            std.mem.eql(u8, call.function, "isnumeric"))
        {
            return self.evaluateCoreUnaryCall(call, mapping);
        }
        if (std.mem.eql(u8, call.function, "langmatches") or
            std.mem.eql(u8, call.function, "sameterm"))
        {
            return self.evaluateCoreBinaryCall(call, mapping);
        }
        if (std.mem.eql(u8, call.function, "strlen") or
            std.mem.eql(u8, call.function, "ucase") or
            std.mem.eql(u8, call.function, "lcase") or
            std.mem.eql(u8, call.function, "encode_for_uri"))
        {
            return self.evaluateStringUnaryCall(call, mapping);
        }
        if (std.mem.eql(u8, call.function, "contains") or
            std.mem.eql(u8, call.function, "strstarts") or
            std.mem.eql(u8, call.function, "strends") or
            std.mem.eql(u8, call.function, "strbefore") or
            std.mem.eql(u8, call.function, "strafter") or
            std.mem.eql(u8, call.function, "strlang") or
            std.mem.eql(u8, call.function, "strdt"))
        {
            return self.evaluateStringBinaryCall(call, mapping);
        }
        if (std.mem.eql(u8, call.function, "concat")) {
            return self.evaluateConcat(call, mapping);
        }
        if (std.mem.eql(u8, call.function, "substr")) {
            return self.evaluateSubstring(call, mapping);
        }
        return .{ .fault = error.UnsupportedExpression };
    }

    fn evaluateCoreUnaryCall(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 1) return .{ .fault = error.UnsupportedExpression };
        const result = try self.evaluate(arguments[0], mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => return result,
        };
        const view = self.terms.view(value) orelse return .{ .fault = error.UnknownTerm };

        if (std.mem.eql(u8, call.function, "str")) return self.evaluateStr(view);
        if (std.mem.eql(u8, call.function, "lang")) return self.evaluateLang(view);
        if (std.mem.eql(u8, call.function, "datatype")) return self.evaluateDatatype(view);
        if (std.mem.eql(u8, call.function, "iri") or std.mem.eql(u8, call.function, "uri")) {
            return self.evaluateIri(view);
        }
        if (std.mem.eql(u8, call.function, "abs") or
            std.mem.eql(u8, call.function, "ceil") or
            std.mem.eql(u8, call.function, "floor") or
            std.mem.eql(u8, call.function, "round"))
        {
            return self.evaluateNumericCall(call.function, value);
        }

        const predicate = if (std.mem.eql(u8, call.function, "isiri") or
            std.mem.eql(u8, call.function, "isuri"))
            view == .named_node
        else if (std.mem.eql(u8, call.function, "isblank"))
            view == .blank_node
        else if (std.mem.eql(u8, call.function, "isliteral"))
            view == .literal
        else if (std.mem.eql(u8, call.function, "isnumeric"))
            termViewIsNumeric(view)
        else
            return .{ .fault = error.UnsupportedExpression };
        return self.internBoolean(predicate);
    }

    fn evaluateCoreBinaryCall(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 2) return .{ .fault = error.UnsupportedExpression };
        const left_result = try self.evaluate(arguments[0], mapping);
        const left = switch (left_result) {
            .value => |value| value,
            .fault => return left_result,
        };
        const right_result = try self.evaluate(arguments[1], mapping);
        const right = switch (right_result) {
            .value => |value| value,
            .fault => return right_result,
        };

        if (std.mem.eql(u8, call.function, "sameterm")) {
            const equal = self.terms.eqlTerm(left, &self.terms, right) catch
                return .{ .fault = error.UnknownTerm };
            return self.internBoolean(equal);
        }
        if (std.mem.eql(u8, call.function, "langmatches")) {
            const language = self.simpleString(left) catch |fault| return .{ .fault = fault };
            const range = self.simpleString(right) catch |fault| return .{ .fault = fault };
            return self.internBoolean(languageMatches(language, range));
        }
        return .{ .fault = error.UnsupportedExpression };
    }

    fn evaluateStr(
        self: *ExpressionEvaluator,
        view: rdf.TermView,
    ) std.mem.Allocator.Error!ExpressionResult {
        const lexical = switch (view) {
            .named_node => |iri| iri,
            .literal => |literal| literal.lexical_form,
            .blank_node => return .{ .fault = error.TypeError },
        };
        return self.internComputedLiteral(lexical, rdf.xsd_string);
    }

    fn evaluateLang(
        self: *ExpressionEvaluator,
        view: rdf.TermView,
    ) std.mem.Allocator.Error!ExpressionResult {
        const literal = switch (view) {
            .literal => |value| value,
            else => return .{ .fault = error.TypeError },
        };
        return self.internComputedLiteral(literal.language orelse "", rdf.xsd_string);
    }

    fn evaluateDatatype(
        self: *ExpressionEvaluator,
        view: rdf.TermView,
    ) std.mem.Allocator.Error!ExpressionResult {
        const literal = switch (view) {
            .literal => |value| value,
            else => return .{ .fault = error.TypeError },
        };
        return self.internNamedNode(literal.datatype);
    }

    fn evaluateIri(
        self: *ExpressionEvaluator,
        view: rdf.TermView,
    ) std.mem.Allocator.Error!ExpressionResult {
        switch (view) {
            .named_node => |iri| return self.internNamedNode(iri),
            .literal => |literal| {
                if (!std.mem.eql(u8, literal.datatype, rdf.xsd_string)) {
                    return .{ .fault = error.TypeError };
                }
                if (iri_mod.isAbsolute(literal.lexical_form)) {
                    return self.internNamedNode(literal.lexical_form);
                }
                const base = self.query.base_iri orelse return .{ .fault = error.TypeError };
                const resolved = iri_mod.resolveAlloc(
                    self.allocator,
                    base,
                    literal.lexical_form,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => .{ .fault = error.TypeError },
                };
                defer self.allocator.free(resolved);
                return self.internNamedNode(resolved);
            },
            .blank_node => return .{ .fault = error.TypeError },
        }
    }

    fn evaluateNumericCall(
        self: *ExpressionEvaluator,
        function: []const u8,
        value: rdf.TermId,
    ) std.mem.Allocator.Error!ExpressionResult {
        const numeric = self.numericValue(value) catch |fault| return .{ .fault = fault };
        return switch (numeric) {
            .integer => |integer| if (std.mem.eql(u8, function, "abs")) absolute: {
                if (integer >= 0) break :absolute .{ .value = value };
                const positive = @subWithOverflow(@as(i128, 0), integer);
                if (positive[1] != 0) break :absolute .{ .fault = error.TypeError };
                break :absolute self.internInteger(positive[0]);
            } else .{ .value = value },
            .decimal => |number| self.evaluateFloatingCall(function, number, rdf.xsd_decimal),
            .float32 => |number| self.evaluateFloatingCall(function, number, rdf.xsd_float),
            .double => |number| self.evaluateFloatingCall(function, number, rdf.xsd_double),
        };
    }

    fn evaluateFloatingCall(
        self: *ExpressionEvaluator,
        function: []const u8,
        number: f64,
        datatype: []const u8,
    ) std.mem.Allocator.Error!ExpressionResult {
        const value = if (std.mem.eql(u8, function, "abs"))
            @abs(number)
        else if (std.mem.eql(u8, function, "ceil"))
            @ceil(number)
        else if (std.mem.eql(u8, function, "floor"))
            @floor(number)
        else if (std.mem.eql(u8, function, "round"))
            @floor(number + 0.5)
        else
            return .{ .fault = error.UnsupportedExpression };
        return self.internFloat(value, datatype);
    }

    fn simpleString(self: *const ExpressionEvaluator, value: rdf.TermId) ExpressionFault![]const u8 {
        const view = self.terms.view(value) orelse return error.UnknownTerm;
        const literal = switch (view) {
            .literal => |item| item,
            else => return error.TypeError,
        };
        if (!std.mem.eql(u8, literal.datatype, rdf.xsd_string)) return error.TypeError;
        return literal.lexical_form;
    }

    fn evaluateStringUnaryCall(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 1) return .{ .fault = error.UnsupportedExpression };
        const result = try self.evaluate(arguments[0], mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => return result,
        };
        const string = self.stringLiteral(value) catch |fault| return .{ .fault = fault };
        if (std.mem.eql(u8, call.function, "strlen")) {
            const length = std.unicode.utf8CountCodepoints(string.lexical) catch
                return .{ .fault = error.TypeError };
            return self.internInteger(@intCast(length));
        }
        if (std.mem.eql(u8, call.function, "encode_for_uri")) {
            const encoded = try encodeForUriAlloc(self.allocator, string.lexical);
            defer self.allocator.free(encoded);
            return self.internComputedLiteral(encoded, rdf.xsd_string);
        }

        const transformed = try self.allocator.dupe(u8, string.lexical);
        defer self.allocator.free(transformed);
        for (transformed) |*byte| {
            byte.* = if (std.mem.eql(u8, call.function, "ucase"))
                std.ascii.toUpper(byte.*)
            else
                std.ascii.toLower(byte.*);
        }
        return self.internStringLiteral(transformed, string.language);
    }

    fn evaluateStringBinaryCall(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 2) return .{ .fault = error.UnsupportedExpression };
        const left_result = try self.evaluate(arguments[0], mapping);
        const left_id = switch (left_result) {
            .value => |value| value,
            .fault => return left_result,
        };
        const right_result = try self.evaluate(arguments[1], mapping);
        const right_id = switch (right_result) {
            .value => |value| value,
            .fault => return right_result,
        };

        if (std.mem.eql(u8, call.function, "strlang")) {
            const lexical = self.simpleString(left_id) catch |fault| return .{ .fault = fault };
            const language = self.simpleString(right_id) catch |fault| return .{ .fault = fault };
            const id = self.terms.internLanguageLiteral(lexical, language) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .{ .fault = error.TypeError },
            };
            return .{ .value = id };
        }
        if (std.mem.eql(u8, call.function, "strdt")) {
            const lexical = self.simpleString(left_id) catch |fault| return .{ .fault = fault };
            const datatype = switch (self.terms.view(right_id) orelse
                return .{ .fault = error.UnknownTerm }) {
                .named_node => |iri| iri,
                else => return .{ .fault = error.TypeError },
            };
            return self.internComputedLiteral(lexical, datatype);
        }

        const left = self.stringLiteral(left_id) catch |fault| return .{ .fault = fault };
        const right = self.stringLiteral(right_id) catch |fault| return .{ .fault = fault };
        if (!stringArgumentsCompatible(left, right)) return .{ .fault = error.TypeError };
        if (std.mem.eql(u8, call.function, "contains")) {
            return self.internBoolean(std.mem.indexOf(u8, left.lexical, right.lexical) != null);
        }
        if (std.mem.eql(u8, call.function, "strstarts")) {
            return self.internBoolean(std.mem.startsWith(u8, left.lexical, right.lexical));
        }
        if (std.mem.eql(u8, call.function, "strends")) {
            return self.internBoolean(std.mem.endsWith(u8, left.lexical, right.lexical));
        }
        const position = std.mem.indexOf(u8, left.lexical, right.lexical);
        if (std.mem.eql(u8, call.function, "strbefore")) {
            return self.internStringLiteral(
                if (position) |index| left.lexical[0..index] else "",
                left.language,
            );
        }
        if (std.mem.eql(u8, call.function, "strafter")) {
            return self.internStringLiteral(
                if (position) |index| left.lexical[index + right.lexical.len ..] else "",
                left.language,
            );
        }
        return .{ .fault = error.UnsupportedExpression };
    }

    fn evaluateConcat(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.allocator);
        var common_language: ?[]const u8 = null;
        var all_same_language = arguments.len != 0;
        for (arguments, 0..) |argument, index| {
            const result = try self.evaluate(argument, mapping);
            const value = switch (result) {
                .value => |item| item,
                .fault => return result,
            };
            const string = self.stringLiteral(value) catch |fault| return .{ .fault = fault };
            try joined.appendSlice(self.allocator, string.lexical);
            if (index == 0) {
                common_language = string.language;
            } else if (!optionalStringEql(common_language, string.language)) {
                all_same_language = false;
            }
            if (string.language == null) all_same_language = false;
        }
        return self.internStringLiteral(
            joined.items,
            if (all_same_language) common_language else null,
        );
    }

    fn evaluateSubstring(
        self: *ExpressionEvaluator,
        call: sparql.FunctionCall,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!ExpressionResult {
        const arguments = self.query.expressionArguments(call.arguments) orelse
            return .{ .fault = error.UnsupportedExpression };
        if (arguments.len != 2 and arguments.len != 3) {
            return .{ .fault = error.UnsupportedExpression };
        }
        const string_result = try self.evaluate(arguments[0], mapping);
        const string_id = switch (string_result) {
            .value => |value| value,
            .fault => return string_result,
        };
        const string = self.stringLiteral(string_id) catch |fault| return .{ .fault = fault };
        const start = (try self.evaluateNumericArgument(arguments[1], mapping)) orelse
            return .{ .fault = error.TypeError };
        const length = if (arguments.len == 3)
            (try self.evaluateNumericArgument(arguments[2], mapping)) orelse
                return .{ .fault = error.TypeError }
        else
            null;
        const slice = utf8Substring(string.lexical, start, length) catch
            return .{ .fault = error.TypeError };
        return self.internStringLiteral(slice, string.language);
    }

    fn evaluateNumericArgument(
        self: *ExpressionEvaluator,
        expression_id: sparql.ExpressionId,
        mapping: SolutionMapping,
    ) std.mem.Allocator.Error!?f64 {
        const result = try self.evaluate(expression_id, mapping);
        const value = switch (result) {
            .value => |item| item,
            .fault => return null,
        };
        const numeric = self.numericValue(value) catch return null;
        return numericAsF64(numeric);
    }

    fn stringLiteral(self: *const ExpressionEvaluator, value: rdf.TermId) ExpressionFault!StringValue {
        const view = self.terms.view(value) orelse return error.UnknownTerm;
        const literal = switch (view) {
            .literal => |item| item,
            else => return error.TypeError,
        };
        if (!std.mem.eql(u8, literal.datatype, rdf.xsd_string) and
            !std.mem.eql(u8, literal.datatype, rdf.rdf_lang_string)) return error.TypeError;
        return .{ .lexical = literal.lexical_form, .language = literal.language };
    }

    fn internStringLiteral(
        self: *ExpressionEvaluator,
        lexical: []const u8,
        language: ?[]const u8,
    ) std.mem.Allocator.Error!ExpressionResult {
        if (language) |tag| {
            const id = self.terms.internLanguageLiteral(lexical, tag) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .{ .fault = error.TypeError },
            };
            return .{ .value = id };
        }
        return self.internComputedLiteral(lexical, rdf.xsd_string);
    }
};

const BooleanResult = union(enum) {
    value: bool,
    fault: ExpressionFault,
};

const NumericValue = union(enum) {
    integer: i128,
    decimal: f64,
    float32: f32,
    double: f64,
};

const StringValue = struct {
    lexical: []const u8,
    language: ?[]const u8,
};

fn numericAsF64(value: NumericValue) f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .decimal => |number| number,
        .float32 => |number| number,
        .double => |number| number,
    };
}

fn numericRank(value: NumericValue) u8 {
    return switch (value) {
        .integer => 0,
        .decimal => 1,
        .float32 => 2,
        .double => 3,
    };
}

fn promotedNumericDatatype(left: NumericValue, right: NumericValue, division: bool) []const u8 {
    const rank = @max(numericRank(left), numericRank(right));
    if (rank == 3) return rdf.xsd_double;
    if (rank == 2) return rdf.xsd_float;
    if (rank == 1 or division) return rdf.xsd_decimal;
    return rdf.xsd_integer;
}

fn compareNumeric(
    left: NumericValue,
    right: NumericValue,
    operator: sparql.BinaryOperator,
) ExpressionFault!bool {
    if (left == .integer and right == .integer) {
        return compareOrder(std.math.order(left.integer, right.integer), operator);
    }
    const left_number = numericAsF64(left);
    const right_number = numericAsF64(right);
    if (std.math.isNan(left_number) or std.math.isNan(right_number)) {
        return switch (operator) {
            .equal, .less, .less_equal, .greater, .greater_equal => false,
            .not_equal => true,
            else => error.TypeError,
        };
    }
    return compareOrder(std.math.order(left_number, right_number), operator);
}

fn compareLiterals(
    left: rdf.LiteralView,
    right: rdf.LiteralView,
    operator: sparql.BinaryOperator,
) ExpressionFault!bool {
    const boolean_datatype = rdf.xsd_namespace ++ "boolean";
    if (std.mem.eql(u8, left.datatype, boolean_datatype) and
        std.mem.eql(u8, right.datatype, boolean_datatype))
    {
        const left_value = parseBoolean(left.lexical_form) orelse return error.TypeError;
        const right_value = parseBoolean(right.lexical_form) orelse return error.TypeError;
        return compareEqualityOnly(left_value == right_value, operator);
    }

    const left_string = std.mem.eql(u8, left.datatype, rdf.xsd_string);
    const right_string = std.mem.eql(u8, right.datatype, rdf.xsd_string);
    const left_language = std.mem.eql(u8, left.datatype, rdf.rdf_lang_string);
    const right_language = std.mem.eql(u8, right.datatype, rdf.rdf_lang_string);
    if (left_string and right_string) {
        return compareOrder(std.mem.order(u8, left.lexical_form, right.lexical_form), operator);
    }
    if (left_language and right_language and optionalStringEql(left.language, right.language)) {
        return compareOrder(std.mem.order(u8, left.lexical_form, right.lexical_form), operator);
    }

    const same_term = std.mem.eql(u8, left.lexical_form, right.lexical_form) and
        std.mem.eql(u8, left.datatype, right.datatype) and
        optionalStringEql(left.language, right.language);
    if (same_term) return compareEqualityOnly(true, operator);
    return error.TypeError;
}

fn compareEqualityOnly(equal: bool, operator: sparql.BinaryOperator) ExpressionFault!bool {
    return switch (operator) {
        .equal => equal,
        .not_equal => !equal,
        else => error.TypeError,
    };
}

fn compareOrder(order: std.math.Order, operator: sparql.BinaryOperator) ExpressionFault!bool {
    return switch (operator) {
        .equal => order == .eq,
        .not_equal => order != .eq,
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
        else => error.TypeError,
    };
}

fn parseBoolean(lexical: []const u8) ?bool {
    if (std.mem.eql(u8, lexical, "true") or std.mem.eql(u8, lexical, "1")) return true;
    if (std.mem.eql(u8, lexical, "false") or std.mem.eql(u8, lexical, "0")) return false;
    return null;
}

fn languageMatches(language: []const u8, range: []const u8) bool {
    if (std.mem.eql(u8, range, "*")) return language.len != 0;
    if (std.ascii.eqlIgnoreCase(language, range)) return true;
    return language.len > range.len and language[range.len] == '-' and
        std.ascii.eqlIgnoreCase(language[0..range.len], range);
}

fn stringArgumentsCompatible(left: StringValue, right: StringValue) bool {
    return right.language == null or
        (left.language != null and optionalStringEql(left.language, right.language));
}

fn encodeForUriAlloc(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    const hex = "0123456789ABCDEF";
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try encoded.append(allocator, byte);
        } else {
            try encoded.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return encoded.toOwnedSlice(allocator);
}

fn utf8Substring(input: []const u8, start_value: f64, length_value: ?f64) ![]const u8 {
    if (std.math.isNan(start_value) or
        (length_value != null and std.math.isNan(length_value.?))) return error.InvalidSubstring;
    const start = @floor(start_value + 0.5);
    const end = if (length_value) |length| start + @floor(length + 0.5) else std.math.inf(f64);
    if (end <= 1 or end <= start) return input[0..0];

    var byte_index: usize = 0;
    var position: f64 = 1;
    var first: ?usize = null;
    var last: usize = 0;
    while (byte_index < input.len) : (position += 1) {
        const width = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch
            return error.InvalidSubstring;
        const next = byte_index + width;
        if (position >= start and position < end) {
            if (first == null) first = byte_index;
            last = next;
        }
        byte_index = next;
    }
    return if (first) |index| input[index..last] else input[0..0];
}

fn parseNumericFloat(lexical: []const u8) ?f64 {
    if (std.mem.eql(u8, lexical, "INF")) return std.math.inf(f64);
    if (std.mem.eql(u8, lexical, "-INF")) return -std.math.inf(f64);
    if (std.mem.eql(u8, lexical, "NaN")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, lexical) catch null;
}

fn isDecimalLexical(lexical: []const u8) bool {
    if (lexical.len == 0) return false;
    var index: usize = if (lexical[0] == '+' or lexical[0] == '-') 1 else 0;
    if (index == lexical.len) return false;
    var digits: usize = 0;
    var saw_dot = false;
    while (index < lexical.len) : (index += 1) {
        const byte = lexical[index];
        if (byte >= '0' and byte <= '9') {
            digits += 1;
        } else if (byte == '.' and !saw_dot) {
            saw_dot = true;
        } else {
            return false;
        }
    }
    return digits != 0;
}

fn termViewIsNumeric(view: rdf.TermView) bool {
    return switch (view) {
        .literal => |literal| isEffectiveBooleanNumeric(literal.datatype),
        else => false,
    };
}

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
        error.TypeError,
        (try evaluator.evaluate(projection[3].expression.expression, mapping)).fault,
    );
}

test "evaluates numeric unary arithmetic and comparisons" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const three = try source.internTypedLiteral("3", rdf.xsd_integer);
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (+?x AS ?plus) (-?x AS ?minus) (?x + 2 AS ?sum) " ++
            "(?x / 2 AS ?quotient) (?x = 3 AS ?equal) (?x < 4 AS ?less) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "x", .value = three }};
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    const plus = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    const minus = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    const sum = (try evaluator.evaluate(projection[2].expression.expression, mapping)).value;
    const quotient = (try evaluator.evaluate(projection[3].expression.expression, mapping)).value;
    try std.testing.expectEqualStrings("3", evaluator.terms.view(plus).?.literal.lexical_form);
    try std.testing.expectEqualStrings("-3", evaluator.terms.view(minus).?.literal.lexical_form);
    try std.testing.expectEqualStrings("5", evaluator.terms.view(sum).?.literal.lexical_form);
    const quotient_view = evaluator.terms.view(quotient).?.literal;
    try std.testing.expectEqualStrings("1.5", quotient_view.lexical_form);
    try std.testing.expectEqualStrings(rdf.xsd_decimal, quotient_view.datatype);

    const equal = (try evaluator.evaluate(projection[4].expression.expression, mapping)).value;
    const less = (try evaluator.evaluate(projection[5].expression.expression, mapping)).value;
    try std.testing.expect(try evaluator.effectiveBooleanValue(equal));
    try std.testing.expect(try evaluator.effectiveBooleanValue(less));
}

test "propagates logical expression errors with SPARQL truth tables" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT ((true || ?missing) AS ?or_true) ((false && ?missing) AS ?and_false) " ++
            "((false || ?missing) AS ?or_error) ((true && ?missing) AS ?and_error) {}",
    );
    defer query.deinit();
    var no_bindings = [_]SolutionBinding{};
    const mapping = SolutionMapping{ .bindings = no_bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    const or_true = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    const and_false = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    try std.testing.expect(try evaluator.effectiveBooleanValue(or_true));
    try std.testing.expect(!try evaluator.effectiveBooleanValue(and_false));
    try std.testing.expectEqual(
        error.UnboundVariable,
        (try evaluator.evaluate(projection[2].expression.expression, mapping)).fault,
    );
    try std.testing.expectEqual(
        error.UnboundVariable,
        (try evaluator.evaluate(projection[3].expression.expression, mapping)).fault,
    );
}

test "evaluates membership and retains errors when no candidate matches" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT ((3 IN (?missing, 3)) AS ?matched) ((3 NOT IN (2, 4)) AS ?outside) " ++
            "((3 IN (?missing, 4)) AS ?failed) {}",
    );
    defer query.deinit();
    var no_bindings = [_]SolutionBinding{};
    const mapping = SolutionMapping{ .bindings = no_bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    const matched = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    const outside = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    try std.testing.expect(try evaluator.effectiveBooleanValue(matched));
    try std.testing.expect(try evaluator.effectiveBooleanValue(outside));
    try std.testing.expectEqual(
        error.UnboundVariable,
        (try evaluator.evaluate(projection[2].expression.expression, mapping)).fault,
    );
}

test "reports numeric faults and compares strings" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const three = try source.internTypedLiteral("3", rdf.xsd_integer);
    const maximum = try source.internTypedLiteral("170141183460469231731687303715884105727", rdf.xsd_integer);
    const malformed = try source.internTypedLiteral("not-an-integer", rdf.xsd_integer);
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT ((?x / 0) AS ?division) ((?maximum + 1) AS ?overflow) " ++
            "((?malformed = ?malformed) AS ?invalid) (('a' < 'b') AS ?ordered) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{
        .{ .variable = "x", .value = three },
        .{ .variable = "maximum", .value = maximum },
        .{ .variable = "malformed", .value = malformed },
    };
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    for (projection[0..3]) |item| {
        try std.testing.expectEqual(
            error.TypeError,
            (try evaluator.evaluate(item.expression.expression, mapping)).fault,
        );
    }
    const ordered = (try evaluator.evaluate(projection[3].expression.expression, mapping)).value;
    try std.testing.expect(try evaluator.effectiveBooleanValue(ordered));
}

test "evaluates RDF term language datatype and IRI built-ins" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const resource = try source.internNamedNode("urn:resource");
    const label = try source.internLanguageLiteral("Hello", "EN-GB");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "BASE <https://example.com/root/> SELECT (STR(?resource) AS ?str) " ++
            "(LANG(?label) AS ?lang) (DATATYPE(?label) AS ?datatype) " ++
            "(IRI('child') AS ?resolved) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{
        .{ .variable = "resource", .value = resource },
        .{ .variable = "label", .value = label },
    };
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;

    const str = (try evaluator.evaluate(projection[0].expression.expression, mapping)).value;
    const lang = (try evaluator.evaluate(projection[1].expression.expression, mapping)).value;
    const datatype = (try evaluator.evaluate(projection[2].expression.expression, mapping)).value;
    const resolved = (try evaluator.evaluate(projection[3].expression.expression, mapping)).value;
    try std.testing.expectEqualStrings("urn:resource", evaluator.terms.view(str).?.literal.lexical_form);
    try std.testing.expectEqualStrings("en-gb", evaluator.terms.view(lang).?.literal.lexical_form);
    try std.testing.expectEqualStrings(rdf.rdf_lang_string, evaluator.terms.view(datatype).?.named_node);
    try std.testing.expectEqualStrings(
        "https://example.com/root/child",
        evaluator.terms.view(resolved).?.named_node,
    );
}

test "evaluates term predicates sameTerm and language matching" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const resource = try source.internNamedNode("urn:resource");
    const blank = try source.internBlankNode("blank");
    const label = try source.internLanguageLiteral("Hello", "en-GB");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (isIRI(?resource) AS ?iri) (isBLANK(?blank) AS ?blank_test) " ++
            "(isLITERAL(?label) AS ?literal) (isNUMERIC(2) AS ?numeric) " ++
            "(sameTerm(?resource, ?resource) AS ?same) " ++
            "(LANGMATCHES(LANG(?label), 'en') AS ?language) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{
        .{ .variable = "resource", .value = resource },
        .{ .variable = "blank", .value = blank },
        .{ .variable = "label", .value = label },
    };
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();

    for (query.projection().items) |item| {
        const result = (try evaluator.evaluate(item.expression.expression, mapping)).value;
        try std.testing.expect(try evaluator.effectiveBooleanValue(result));
    }
}

test "evaluates numeric scalar built-ins and their type faults" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const blank = try source.internBlankNode("blank");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (ABS(-2.5) AS ?abs) (CEIL(1.2) AS ?ceil) (FLOOR(1.8) AS ?floor) " ++
            "(ROUND(-1.5) AS ?round) (STR(?blank) AS ?invalid) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "blank", .value = blank }};
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;
    const expected = [_][]const u8{ "2.5", "2", "1", "-1" };
    for (projection[0..4], expected) |item, lexical| {
        const result = (try evaluator.evaluate(item.expression.expression, mapping)).value;
        try std.testing.expectEqualStrings(lexical, evaluator.terms.view(result).?.literal.lexical_form);
    }
    try std.testing.expectEqual(
        error.TypeError,
        (try evaluator.evaluate(projection[4].expression.expression, mapping)).fault,
    );
}

test "evaluates Unicode-aware string length substring concatenation and URI encoding" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (STRLEN('Aé猫') AS ?length) (SUBSTR('Aé猫Z', 2, 2) AS ?substring) " ++
            "(CONCAT('a', 'b', 'c') AS ?concat) (UCASE('Abé') AS ?upper) " ++
            "(ENCODE_FOR_URI('A é') AS ?encoded) {}",
    );
    defer query.deinit();
    var no_bindings = [_]SolutionBinding{};
    const mapping = SolutionMapping{ .bindings = no_bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;
    const expected = [_][]const u8{ "3", "é猫", "abc", "ABé", "A%20%C3%A9" };
    for (projection, expected) |item, lexical| {
        const result = (try evaluator.evaluate(item.expression.expression, mapping)).value;
        try std.testing.expectEqualStrings(lexical, evaluator.terms.view(result).?.literal.lexical_form);
    }
}

test "preserves language tags through compatible string operations" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    const label = try source.internLanguageLiteral("hello-world", "en");
    const french = try source.internLanguageLiteral("monde", "fr");
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (CONTAINS(?label, 'world') AS ?contains) " ++
            "(STRSTARTS(?label, 'hello') AS ?starts) (STRENDS(?label, 'world') AS ?ends) " ++
            "(STRBEFORE(?label, '-') AS ?before) (STRAFTER(?label, '-') AS ?after) " ++
            "(CONCAT(?label, ?label) AS ?same_language) " ++
            "(CONCAT(?label, ' plain') AS ?mixed) (CONTAINS(?label, ?french) AS ?invalid) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{
        .{ .variable = "label", .value = label },
        .{ .variable = "french", .value = french },
    };
    const mapping = SolutionMapping{ .bindings = bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;
    for (projection[0..3]) |item| {
        const result = (try evaluator.evaluate(item.expression.expression, mapping)).value;
        try std.testing.expect(try evaluator.effectiveBooleanValue(result));
    }
    const before = evaluator.terms.view(
        (try evaluator.evaluate(projection[3].expression.expression, mapping)).value,
    ).?.literal;
    const after = evaluator.terms.view(
        (try evaluator.evaluate(projection[4].expression.expression, mapping)).value,
    ).?.literal;
    const same = evaluator.terms.view(
        (try evaluator.evaluate(projection[5].expression.expression, mapping)).value,
    ).?.literal;
    const mixed = evaluator.terms.view(
        (try evaluator.evaluate(projection[6].expression.expression, mapping)).value,
    ).?.literal;
    try std.testing.expectEqualStrings("hello", before.lexical_form);
    try std.testing.expectEqualStrings("world", after.lexical_form);
    try std.testing.expectEqualStrings("en", before.language.?);
    try std.testing.expectEqualStrings("en", after.language.?);
    try std.testing.expectEqualStrings("en", same.language.?);
    try std.testing.expectEqual(@as(?[]const u8, null), mixed.language);
    try std.testing.expectEqual(
        error.TypeError,
        (try evaluator.evaluate(projection[7].expression.expression, mapping)).fault,
    );
}

test "constructs language-tagged and datatype literals" {
    var source = rdf.TermPool.init(std.testing.allocator);
    defer source.deinit();
    var query = try sparql.parseQuery(
        std.testing.allocator,
        "SELECT (STRLANG('salut', 'RO') AS ?language) " ++
            "(STRDT('3', <http://www.w3.org/2001/XMLSchema#integer>) AS ?typed) " ++
            "(STRLANG('bad', 'en--US') AS ?invalid) {}",
    );
    defer query.deinit();
    var no_bindings = [_]SolutionBinding{};
    const mapping = SolutionMapping{ .bindings = no_bindings[0..] };
    var evaluator = ExpressionEvaluator.init(std.testing.allocator, &query, &source);
    defer evaluator.deinit();
    const projection = query.projection().items;
    const language = evaluator.terms.view(
        (try evaluator.evaluate(projection[0].expression.expression, mapping)).value,
    ).?.literal;
    const typed = evaluator.terms.view(
        (try evaluator.evaluate(projection[1].expression.expression, mapping)).value,
    ).?.literal;
    try std.testing.expectEqualStrings("ro", language.language.?);
    try std.testing.expectEqualStrings(rdf.xsd_integer, typed.datatype);
    try std.testing.expectEqual(
        error.TypeError,
        (try evaluator.evaluate(projection[2].expression.expression, mapping)).fault,
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
    const value = try source.internTypedLiteral("3", rdf.xsd_integer);
    var query = try sparql.parseQuery(
        allocator,
        "SELECT (CONCAT(STR(ABS(?input + 2)), SUBSTR('value', 2)) AS ?output) {}",
    );
    defer query.deinit();
    var bindings = [_]SolutionBinding{.{ .variable = "input", .value = value }};
    var evaluator = ExpressionEvaluator.init(allocator, &query, &source);
    defer evaluator.deinit();
    const expression_id = query.projection().items[0].expression.expression;
    const result = try evaluator.evaluate(expression_id, .{ .bindings = bindings[0..] });
    try std.testing.expect(result == .value);
    try std.testing.expectEqualStrings("5alue", evaluator.terms.view(result.value).?.literal.lexical_form);
}

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
    ask,
    construct,
    distinct,
    reduced,
    where,
    as,
    separator,
    filter,
    bind,
    in,
    not,
    exists,
    minus_keyword,
    union_keyword,
    optional,
    graph_keyword,
    service,
    silent,
    from,
    named,
    group_keyword,
    by,
    having,
    order,
    ascending,
    descending,
    limit,
    offset_keyword,
    values_keyword,
    undef,
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
    left_parenthesis,
    right_parenthesis,
    semicolon,
    comma,
    slash,
    pipe,
    caret,
    bang,
    plus,
    minus,
    question,
    equals,
    not_equals,
    less,
    less_equal,
    greater,
    greater_equal,
    logical_and,
    logical_or,
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
            '(' => self.single(.left_parenthesis),
            ')' => self.single(.right_parenthesis),
            ';' => self.single(.semicolon),
            ',' => self.single(.comma),
            '/' => self.single(.slash),
            '|' => if (self.index + 1 < self.input.len and self.input[self.index + 1] == '|')
                self.pair(.logical_or)
            else
                self.single(.pipe),
            '&' => if (self.index + 1 < self.input.len and self.input[self.index + 1] == '&')
                self.pair(.logical_and)
            else
                error.InvalidSyntax,
            '!' => if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=')
                self.pair(.not_equals)
            else
                self.single(.bang),
            '+' => if (self.index + 1 < self.input.len and
                (std.ascii.isDigit(self.input[self.index + 1]) or
                    self.input[self.index + 1] == '.'))
                self.word(offset)
            else
                self.single(.plus),
            '-' => if (self.index + 1 < self.input.len and
                (std.ascii.isDigit(self.input[self.index + 1]) or
                    self.input[self.index + 1] == '.'))
                self.word(offset)
            else
                self.single(.minus),
            '=' => self.single(.equals),
            '>' => if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=')
                self.pair(.greater_equal)
            else
                self.single(.greater),
            '.' => if (self.index + 1 < self.input.len and
                std.ascii.isDigit(self.input[self.index + 1]))
                self.word(offset)
            else
                self.single(.dot),
            '*' => self.single(.star),
            '?' => if (self.index + 1 < self.input.len and
                !isDelimiter(self.input[self.index + 1]))
                self.variable()
            else
                self.single(.question),
            '$' => self.variable(),
            '<' => self.lessOrIriReference(),
            '"', '\'' => self.stringLiteral(),
            '@' => self.languageTag(),
            '^' => if (self.index + 1 < self.input.len and self.input[self.index + 1] == '^')
                self.datatypeMarker()
            else
                self.single(.caret),
            else => self.word(offset),
        };
    }

    fn single(self: *Tokenizer, tag: TokenTag) Token {
        const offset = self.index;
        self.index += 1;
        return .{ .tag = tag, .lexeme = self.input[offset..self.index], .offset = offset };
    }

    fn pair(self: *Tokenizer, tag: TokenTag) Token {
        const offset = self.index;
        self.index += 2;
        return .{ .tag = tag, .lexeme = self.input[offset..self.index], .offset = offset };
    }

    fn lessOrIriReference(self: *Tokenizer) ParseError!Token {
        if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=') {
            return self.pair(.less_equal);
        }
        var cursor = self.index + 1;
        while (cursor < self.input.len) {
            const byte = self.input[cursor];
            if (byte == '>') return self.iriReference();
            if (isWhitespace(byte) or byte == '<' or byte == '"' or byte == '{' or
                byte == '}' or byte == '|' or byte == '^' or byte == '`')
            {
                return self.single(.less);
            }
            if (byte == '\\') {
                cursor += 1;
                if (cursor >= self.input.len or
                    (self.input[cursor] != 'u' and self.input[cursor] != 'U'))
                {
                    return self.single(.less);
                }
                cursor += if (self.input[cursor] == 'u') 5 else 9;
                continue;
            }
            cursor += utf8Length(self.input, cursor) orelse return error.InvalidSyntax;
        }
        return self.single(.less);
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
        while (self.index < self.input.len) {
            if (isWordDelimiter(self.input[self.index])) {
                if (self.input[self.index] == '+' and self.index == offset) {
                    self.index += 1;
                    continue;
                }
                if (self.input[self.index] == '+' and
                    isNumericExponentPrefix(self.input[offset..self.index]))
                {
                    self.index += 1;
                    continue;
                }
                break;
            }
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
        else if (std.ascii.eqlIgnoreCase(lexeme, "ASK"))
            .ask
        else if (std.ascii.eqlIgnoreCase(lexeme, "CONSTRUCT"))
            .construct
        else if (std.ascii.eqlIgnoreCase(lexeme, "DISTINCT"))
            .distinct
        else if (std.ascii.eqlIgnoreCase(lexeme, "REDUCED"))
            .reduced
        else if (std.ascii.eqlIgnoreCase(lexeme, "WHERE"))
            .where
        else if (std.ascii.eqlIgnoreCase(lexeme, "AS"))
            .as
        else if (std.ascii.eqlIgnoreCase(lexeme, "SEPARATOR"))
            .separator
        else if (std.ascii.eqlIgnoreCase(lexeme, "FILTER"))
            .filter
        else if (std.ascii.eqlIgnoreCase(lexeme, "BIND"))
            .bind
        else if (std.ascii.eqlIgnoreCase(lexeme, "IN"))
            .in
        else if (std.ascii.eqlIgnoreCase(lexeme, "NOT"))
            .not
        else if (std.ascii.eqlIgnoreCase(lexeme, "EXISTS"))
            .exists
        else if (std.ascii.eqlIgnoreCase(lexeme, "MINUS"))
            .minus_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "UNION"))
            .union_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "OPTIONAL"))
            .optional
        else if (std.ascii.eqlIgnoreCase(lexeme, "GRAPH"))
            .graph_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "SERVICE"))
            .service
        else if (std.ascii.eqlIgnoreCase(lexeme, "SILENT"))
            .silent
        else if (std.ascii.eqlIgnoreCase(lexeme, "FROM"))
            .from
        else if (std.ascii.eqlIgnoreCase(lexeme, "NAMED"))
            .named
        else if (std.ascii.eqlIgnoreCase(lexeme, "GROUP"))
            .group_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "BY"))
            .by
        else if (std.ascii.eqlIgnoreCase(lexeme, "HAVING"))
            .having
        else if (std.ascii.eqlIgnoreCase(lexeme, "ORDER"))
            .order
        else if (std.ascii.eqlIgnoreCase(lexeme, "ASC"))
            .ascending
        else if (std.ascii.eqlIgnoreCase(lexeme, "DESC"))
            .descending
        else if (std.ascii.eqlIgnoreCase(lexeme, "LIMIT"))
            .limit
        else if (std.ascii.eqlIgnoreCase(lexeme, "OFFSET"))
            .offset_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "VALUES"))
            .values_keyword
        else if (std.ascii.eqlIgnoreCase(lexeme, "UNDEF"))
            .undef
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
    path: PathId,
    blank_node: BlankNode,
    literal: Literal,
};

pub const PathId = usize;

pub const BinaryPath = struct {
    left: PathId,
    right: PathId,
};

pub const NegatedProperty = struct {
    iri: []const u8,
    inverse: bool = false,
};

pub const NegatedPropertySet = struct {
    start: usize,
    len: usize,
};

pub const Path = union(enum) {
    iri: []const u8,
    inverse: PathId,
    sequence: BinaryPath,
    alternative: BinaryPath,
    zero_or_more: PathId,
    one_or_more: PathId,
    zero_or_one: PathId,
    negated_property_set: NegatedPropertySet,
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

pub const ExpressionId = usize;

pub const UnaryOperator = enum { plus, minus, logical_not };
pub const BinaryOperator = enum {
    logical_or,
    logical_and,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    add,
    subtract,
    multiply,
    divide,
};

pub const UnaryExpression = struct {
    operator: UnaryOperator,
    operand: ExpressionId,
};

pub const BinaryExpression = struct {
    operator: BinaryOperator,
    left: ExpressionId,
    right: ExpressionId,
};

pub const ExpressionRange = struct {
    start: usize,
    len: usize,
};

pub const SolutionRange = struct {
    start: usize = 0,
    len: usize = 0,
};

pub const GroupCondition = struct {
    expression: ExpressionId,
    alias: ?[]const u8 = null,
};

pub const OrderDirection = enum { default, ascending, descending };

pub const OrderCondition = struct {
    expression: ExpressionId,
    direction: OrderDirection = .default,
};

pub const SolutionModifiers = struct {
    group_by: SolutionRange = .{},
    having: SolutionRange = .{},
    order_by: SolutionRange = .{},
    limit: ?usize = null,
    offset: ?usize = null,
};

pub const FunctionCall = struct {
    function: []const u8,
    arguments: ExpressionRange,
    distinct: bool = false,
    separator: ?ExpressionId = null,
};

pub const MembershipExpression = struct {
    operand: ExpressionId,
    values: ExpressionRange,
    negated: bool = false,
};

pub const GroupId = usize;
pub const SubqueryId = usize;
pub const ValuesId = usize;

pub const ExistsExpression = struct {
    group: GroupId,
    negated: bool = false,
};

pub const Expression = union(enum) {
    variable: []const u8,
    iri: []const u8,
    literal: Literal,
    wildcard,
    unary: UnaryExpression,
    binary: BinaryExpression,
    membership: MembershipExpression,
    exists: ExistsExpression,
    call: FunctionCall,
};

pub const Binding = struct {
    expression: ExpressionId,
    variable: []const u8,
};

pub const BinaryGroup = struct {
    left: GroupId,
    right: GroupId,
};

pub const GraphSelector = union(enum) {
    variable: []const u8,
    iri: []const u8,
};

pub const GraphPattern = struct {
    selector: GraphSelector,
    group: GroupId,
};

pub const ServicePattern = struct {
    selector: GraphSelector,
    group: GroupId,
    silent: bool = false,
};

pub const GroupElement = union(enum) {
    triple: usize,
    filter: ExpressionId,
    bind: Binding,
    group: GroupId,
    optional: GroupId,
    minus: GroupId,
    union_group: BinaryGroup,
    subquery: SubqueryId,
    values: ValuesId,
    graph: GraphPattern,
    service: ServicePattern,
};

const Group = struct {
    elements: std.ArrayList(GroupElement) = .empty,
};

pub const Subquery = struct {
    modifier: Modifier,
    select_all: bool,
    projection_variables: []const []const u8,
    projection_items: []const ProjectionItem,
    group: GroupId,
    solution: SolutionModifiers,
    trailing_values: ?ValuesId,

    pub fn projection(self: Subquery) Projection {
        if (self.select_all) return .all;
        if (self.projection_variables.len == self.projection_items.len) {
            return .{ .variables = self.projection_variables };
        }
        return .{ .items = self.projection_items };
    }
};

pub const DataValue = union(enum) {
    term: PatternTerm,
    undefined,
};

pub const ValuesBlock = struct {
    variables: []const []const u8,
    cells: []const DataValue,
    row_count: usize,

    pub fn value(self: ValuesBlock, row: usize, column: usize) ?DataValue {
        if (row >= self.row_count or column >= self.variables.len) return null;
        return self.cells[row * self.variables.len + column];
    }
};

pub const QueryForm = enum { select, ask, construct };

pub const DatasetClause = struct {
    iri: []const u8,
    named: bool = false,
};

pub const ProjectionExpression = struct {
    expression: ExpressionId,
    alias: []const u8,
};

pub const ProjectionItem = union(enum) {
    variable: []const u8,
    expression: ProjectionExpression,
};

pub const Projection = union(enum) {
    all,
    variables: []const []const u8,
    items: []const ProjectionItem,
};

pub const Prefix = struct {
    name: []const u8,
    namespace: []const u8,
};

/// Allocator-owned syntax tree for the implemented SPARQL query slice.
pub const Query = struct {
    allocator: std.mem.Allocator,
    base_iri: ?[]const u8 = null,
    form: QueryForm = .select,
    modifier: Modifier,
    select_all: bool,
    prefixes: std.ArrayList(Prefix) = .empty,
    projection_variables: std.ArrayList([]const u8) = .empty,
    projection_items: std.ArrayList(ProjectionItem) = .empty,
    where_patterns: std.ArrayList(TriplePattern) = .empty,
    groups: std.ArrayList(Group) = .empty,
    subqueries: std.ArrayList(Subquery) = .empty,
    values_blocks: std.ArrayList(ValuesBlock) = .empty,
    root_group: ?GroupId = null,
    dataset_clauses: std.ArrayList(DatasetClause) = .empty,
    solution: SolutionModifiers = .{},
    trailing_values: ?ValuesId = null,
    paths: std.ArrayList(Path) = .empty,
    negated_properties: std.ArrayList(NegatedProperty) = .empty,
    expressions: std.ArrayList(Expression) = .empty,
    expression_arguments: std.ArrayList(ExpressionId) = .empty,
    group_conditions: std.ArrayList(GroupCondition) = .empty,
    having_conditions: std.ArrayList(ExpressionId) = .empty,
    order_conditions: std.ArrayList(OrderCondition) = .empty,
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
        self.projection_items.deinit(self.allocator);
        self.where_patterns.deinit(self.allocator);
        for (self.groups.items) |*group| group.elements.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        for (self.subqueries.items) |nested_query| {
            self.allocator.free(nested_query.projection_variables);
            self.allocator.free(nested_query.projection_items);
        }
        self.subqueries.deinit(self.allocator);
        for (self.values_blocks.items) |block| {
            self.allocator.free(block.variables);
            self.allocator.free(block.cells);
        }
        self.values_blocks.deinit(self.allocator);
        self.dataset_clauses.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.negated_properties.deinit(self.allocator);
        self.expressions.deinit(self.allocator);
        self.expression_arguments.deinit(self.allocator);
        self.group_conditions.deinit(self.allocator);
        self.having_conditions.deinit(self.allocator);
        self.order_conditions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn projection(self: *const Query) Projection {
        if (self.select_all) return .all;
        if (self.projection_variables.items.len == self.projection_items.items.len) {
            return .{ .variables = self.projection_variables.items };
        }
        return .{ .items = self.projection_items.items };
    }

    pub fn projectionItems(self: *const Query) []const ProjectionItem {
        return self.projection_items.items;
    }

    pub fn patterns(self: *const Query) []const TriplePattern {
        return self.where_patterns.items;
    }

    pub fn prefixDeclarations(self: *const Query) []const Prefix {
        return self.prefixes.items;
    }

    pub fn path(self: *const Query, id: PathId) ?Path {
        if (id >= self.paths.items.len) return null;
        return self.paths.items[id];
    }

    pub fn expression(self: *const Query, id: ExpressionId) ?Expression {
        if (id >= self.expressions.items.len) return null;
        return self.expressions.items[id];
    }

    pub fn expressionArguments(self: *const Query, range: ExpressionRange) ?[]const ExpressionId {
        if (range.start > self.expression_arguments.items.len or
            range.len > self.expression_arguments.items.len - range.start)
        {
            return null;
        }
        return self.expression_arguments.items[range.start..][0..range.len];
    }

    pub fn groupElements(self: *const Query, id: GroupId) ?[]const GroupElement {
        if (id >= self.groups.items.len) return null;
        return self.groups.items[id].elements.items;
    }

    pub fn subquery(self: *const Query, id: SubqueryId) ?Subquery {
        if (id >= self.subqueries.items.len) return null;
        return self.subqueries.items[id];
    }

    pub fn datasetClauses(self: *const Query) []const DatasetClause {
        return self.dataset_clauses.items;
    }

    pub fn values(self: *const Query, id: ValuesId) ?ValuesBlock {
        if (id >= self.values_blocks.items.len) return null;
        return self.values_blocks.items[id];
    }

    pub fn trailingValues(self: *const Query) ?ValuesBlock {
        return self.values(self.trailing_values orelse return null);
    }

    pub fn groupBy(self: *const Query) []const GroupCondition {
        return self.groupConditions(self.solution.group_by) orelse unreachable;
    }

    pub fn having(self: *const Query) []const ExpressionId {
        return self.havingConditions(self.solution.having) orelse unreachable;
    }

    pub fn orderBy(self: *const Query) []const OrderCondition {
        return self.orderConditions(self.solution.order_by) orelse unreachable;
    }

    pub fn groupConditions(
        self: *const Query,
        range: SolutionRange,
    ) ?[]const GroupCondition {
        return rangeSlice(GroupCondition, self.group_conditions.items, range);
    }

    pub fn havingConditions(
        self: *const Query,
        range: SolutionRange,
    ) ?[]const ExpressionId {
        return rangeSlice(ExpressionId, self.having_conditions.items, range);
    }

    pub fn orderConditions(
        self: *const Query,
        range: SolutionRange,
    ) ?[]const OrderCondition {
        return rangeSlice(OrderCondition, self.order_conditions.items, range);
    }

    pub fn negatedPropertySet(
        self: *const Query,
        set: NegatedPropertySet,
    ) ?[]const NegatedProperty {
        if (set.start > self.negated_properties.items.len or
            set.len > self.negated_properties.items.len - set.start)
        {
            return null;
        }
        return self.negated_properties.items[set.start..][0..set.len];
    }

    /// Produces an allocation-free algebra view borrowing this query's storage.
    pub fn lower(self: *const Query) Algebra {
        const input: AlgebraInput = .{ .bgp = self.basicGraphPattern() };
        return switch (self.form) {
            .select => .{ .project = .{
                .projection = self.projection(),
                .input = input,
                .datasets = self.dataset_clauses.items,
                .group_by = self.groupBy(),
                .having = self.having(),
                .order_by = self.orderBy(),
                .limit = self.solution.limit,
                .offset = self.solution.offset,
                .trailing_values = self.trailingValues(),
                .expressions = self.expressions.items,
                .expression_arguments = self.expression_arguments.items,
            } },
            .ask => .{ .ask = .{
                .input = input,
                .datasets = self.dataset_clauses.items,
                .group_by = self.groupBy(),
                .having = self.having(),
                .order_by = self.orderBy(),
                .limit = self.solution.limit,
                .offset = self.solution.offset,
                .trailing_values = self.trailingValues(),
                .expressions = self.expressions.items,
                .expression_arguments = self.expression_arguments.items,
            } },
            .construct => .{ .construct = .{
                .input = input,
                .datasets = self.dataset_clauses.items,
                .group_by = self.groupBy(),
                .having = self.having(),
                .order_by = self.orderBy(),
                .limit = self.solution.limit,
                .offset = self.solution.offset,
                .trailing_values = self.trailingValues(),
                .expressions = self.expressions.items,
                .expression_arguments = self.expression_arguments.items,
            } },
        };
    }

    fn basicGraphPattern(self: *const Query) BasicGraphPattern {
        return .{
            .triples = self.patterns(),
            .elements = if (self.root_group) |root|
                self.groups.items[root].elements.items
            else
                &.{},
            .groups = .{
                .owner = self,
                .root = self.root_group,
            },
            .paths = self.paths.items,
            .negated_properties = self.negated_properties.items,
        };
    }

    fn own(self: *Query, value: []const u8) std.mem.Allocator.Error![]const u8 {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }
};

pub const GroupTable = struct {
    owner: *const Query,
    root: ?GroupId,

    pub fn elements(self: GroupTable, id: GroupId) ?[]const GroupElement {
        return self.owner.groupElements(id);
    }
};

pub const BasicGraphPattern = struct {
    triples: []const TriplePattern,
    elements: []const GroupElement,
    groups: GroupTable,
    paths: []const Path,
    negated_properties: []const NegatedProperty,
};

pub const Project = struct {
    projection: Projection,
    input: AlgebraInput,
    datasets: []const DatasetClause,
    group_by: []const GroupCondition,
    having: []const ExpressionId,
    order_by: []const OrderCondition,
    limit: ?usize,
    offset: ?usize,
    trailing_values: ?ValuesBlock,
    expressions: []const Expression,
    expression_arguments: []const ExpressionId,
};

pub const Ask = struct {
    input: AlgebraInput,
    datasets: []const DatasetClause,
    group_by: []const GroupCondition,
    having: []const ExpressionId,
    order_by: []const OrderCondition,
    limit: ?usize,
    offset: ?usize,
    trailing_values: ?ValuesBlock,
    expressions: []const Expression,
    expression_arguments: []const ExpressionId,
};

pub const Construct = struct {
    input: AlgebraInput,
    datasets: []const DatasetClause,
    group_by: []const GroupCondition,
    having: []const ExpressionId,
    order_by: []const OrderCondition,
    limit: ?usize,
    offset: ?usize,
    trailing_values: ?ValuesBlock,
    expressions: []const Expression,
    expression_arguments: []const ExpressionId,
};

pub const AlgebraInput = union(enum) {
    bgp: BasicGraphPattern,
};

/// Borrowed SPARQL algebra view. It remains valid while its source `Query` is alive
/// and structurally unchanged.
pub const Algebra = union(enum) {
    project: Project,
    ask: Ask,
    construct: Construct,
};

/// Parses the implemented SPARQL 1.1 SELECT, ASK, and CONSTRUCT query slice.
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
    const ParsedGraphNode = struct {
        term: PatternTerm,
        standalone: bool = false,
    };

    const ProjectionTarget = struct {
        modifier: *Modifier,
        select_all: *bool,
        variables: *std.ArrayList([]const u8),
        items: *std.ArrayList(ProjectionItem),
    };

    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    query: Query,
    lookahead: ?Token = null,
    current_group: ?GroupId = null,

    fn parse(self: *Parser) ParseError!void {
        try self.parsePrologue();
        switch ((try self.peek()).tag) {
            .select => {
                self.query.form = .select;
                try self.parseSelectClause(.{
                    .modifier = &self.query.modifier,
                    .select_all = &self.query.select_all,
                    .variables = &self.query.projection_variables,
                    .items = &self.query.projection_items,
                });
                try self.parseDatasetClauses();
                try self.parseRootWhere(false);
            },
            .ask => {
                _ = try self.take();
                self.query.form = .ask;
                try self.parseDatasetClauses();
                try self.parseRootWhere(false);
            },
            .construct => {
                _ = try self.take();
                self.query.form = .construct;
                try self.parseDatasetClauses();
                try self.parseRootWhere(true);
            },
            else => return error.InvalidSyntax,
        }
        self.query.solution = try self.parseSolutionModifiers();
        if ((try self.peek()).tag == .values_keyword) {
            self.query.trailing_values = try self.parseValuesClause();
        }
        if (self.query.form == .select and !self.projectionAliasesAreValid(
            self.query.projection_items.items,
            self.query.root_group.?,
            self.query.solution.group_by,
            self.query.trailing_values,
        )) return error.InvalidSyntax;
        if (!self.groupAliasesAreValid(
            self.query.solution.group_by,
            self.query.root_group.?,
            self.query.trailing_values,
        )) return error.InvalidSyntax;
        if (self.query.form == .select and !self.groupedProjectionIsValid(
            self.query.projection_items.items,
            self.query.select_all,
            self.query.solution.group_by,
            self.query.trailing_values,
        )) return error.InvalidSyntax;
        try self.expect(.eof);
    }

    fn parseSolutionModifiers(self: *Parser) ParseError!SolutionModifiers {
        var result = SolutionModifiers{
            .group_by = try self.parseGroupBy(),
            .having = try self.parseHaving(),
            .order_by = try self.parseOrderBy(),
        };
        while (true) switch ((try self.peek()).tag) {
            .limit => {
                if (result.limit != null) return error.InvalidSyntax;
                _ = try self.take();
                result.limit = try self.parseUnsignedInteger();
            },
            .offset_keyword => {
                if (result.offset != null) return error.InvalidSyntax;
                _ = try self.take();
                result.offset = try self.parseUnsignedInteger();
            },
            else => return result,
        };
    }

    fn parseGroupBy(self: *Parser) ParseError!SolutionRange {
        const start = self.query.group_conditions.items.len;
        if ((try self.peek()).tag != .group_keyword) {
            return .{ .start = start, .len = 0 };
        }
        _ = try self.take();
        try self.expect(.by);
        while (canStartGroupCondition((try self.peek()).tag)) {
            try self.query.group_conditions.append(
                self.allocator,
                try self.parseGroupCondition(start),
            );
        }
        const len = self.query.group_conditions.items.len - start;
        if (len == 0) return error.InvalidSyntax;
        return .{ .start = start, .len = len };
    }

    fn parseGroupCondition(self: *Parser, start: usize) ParseError!GroupCondition {
        if ((try self.peek()).tag == .left_parenthesis) {
            _ = try self.take();
            const expression_id = try self.parseExpression();
            var alias: ?[]const u8 = null;
            if ((try self.peek()).tag == .as) {
                _ = try self.take();
                const variable = try self.take();
                if (variable.tag != .variable or
                    self.groupConditionHasAlias(start, variable.lexeme))
                {
                    return error.InvalidSyntax;
                }
                alias = try self.query.own(variable.lexeme);
            }
            try self.expect(.right_parenthesis);
            return .{ .expression = expression_id, .alias = alias };
        }

        const first_tag = (try self.peek()).tag;
        const expression_id = try self.parseExpression();
        if (first_tag != .variable and self.query.expressions.items[expression_id] != .call) {
            return error.InvalidSyntax;
        }
        return .{ .expression = expression_id };
    }

    fn groupConditionHasAlias(self: *const Parser, start: usize, name: []const u8) bool {
        for (self.query.group_conditions.items[start..]) |condition| {
            if (condition.alias) |alias| {
                if (std.mem.eql(u8, alias, name)) return true;
            }
        }
        return false;
    }

    fn parseHaving(self: *Parser) ParseError!SolutionRange {
        const start = self.query.having_conditions.items.len;
        if ((try self.peek()).tag != .having) return .{ .start = start, .len = 0 };
        _ = try self.take();
        while (canStartConstraint((try self.peek()).tag)) {
            try self.query.having_conditions.append(
                self.allocator,
                try self.parseConstraint(),
            );
        }
        const len = self.query.having_conditions.items.len - start;
        if (len == 0) return error.InvalidSyntax;
        return .{ .start = start, .len = len };
    }

    fn parseOrderBy(self: *Parser) ParseError!SolutionRange {
        const start = self.query.order_conditions.items.len;
        if ((try self.peek()).tag != .order) return .{ .start = start, .len = 0 };
        _ = try self.take();
        try self.expect(.by);
        while (canStartOrderCondition((try self.peek()).tag)) {
            try self.query.order_conditions.append(
                self.allocator,
                try self.parseOrderCondition(),
            );
        }
        const len = self.query.order_conditions.items.len - start;
        if (len == 0) return error.InvalidSyntax;
        return .{ .start = start, .len = len };
    }

    fn parseOrderCondition(self: *Parser) ParseError!OrderCondition {
        const direction: OrderDirection = switch ((try self.peek()).tag) {
            .ascending => direction: {
                _ = try self.take();
                break :direction .ascending;
            },
            .descending => direction: {
                _ = try self.take();
                break :direction .descending;
            },
            else => .default,
        };
        if (direction != .default) {
            try self.expect(.left_parenthesis);
            const expression_id = try self.parseExpression();
            try self.expect(.right_parenthesis);
            return .{ .expression = expression_id, .direction = direction };
        }
        return .{ .expression = try self.parseConstraintOrVariable() };
    }

    fn parseConstraintOrVariable(self: *Parser) ParseError!ExpressionId {
        if ((try self.peek()).tag == .variable) return self.parseExpression();
        return self.parseConstraint();
    }

    fn parseConstraint(self: *Parser) ParseError!ExpressionId {
        const bracketed = (try self.peek()).tag == .left_parenthesis;
        const expression_id = try self.parseExpression();
        if (!bracketed and self.query.expressions.items[expression_id] != .call and
            self.query.expressions.items[expression_id] != .exists)
        {
            return error.InvalidSyntax;
        }
        return expression_id;
    }

    fn parseUnsignedInteger(self: *Parser) ParseError!usize {
        const token = try self.take();
        if (token.tag != .integer or token.lexeme.len == 0 or
            token.lexeme[0] == '+' or token.lexeme[0] == '-')
        {
            return error.InvalidSyntax;
        }
        return std.fmt.parseInt(usize, token.lexeme, 10) catch return error.InvalidSyntax;
    }

    fn parseSelectClause(self: *Parser, target: ProjectionTarget) ParseError!void {
        try self.expect(.select);
        const modifier = try self.peek();
        if (modifier.tag == .distinct or modifier.tag == .reduced) {
            _ = try self.take();
            target.modifier.* = if (modifier.tag == .distinct) .distinct else .reduced;
        }

        const projection = try self.peek();
        if (projection.tag == .star) {
            _ = try self.take();
            target.select_all.* = true;
        } else {
            while (true) {
                switch ((try self.peek()).tag) {
                    .variable => {
                        const variable = try self.take();
                        if (projectionHasVariable(target.items.items, variable.lexeme)) {
                            return error.InvalidSyntax;
                        }
                        const name = try self.query.own(variable.lexeme);
                        try target.variables.append(self.allocator, name);
                        try target.items.append(
                            self.allocator,
                            .{ .variable = name },
                        );
                    },
                    .left_parenthesis => try self.parseProjectionExpression(target.items),
                    else => break,
                }
            }
            if (target.items.items.len == 0) return error.InvalidSyntax;
        }
    }

    fn parseRootWhere(self: *Parser, require_where: bool) ParseError!void {
        if (require_where) {
            try self.expect(.where);
        } else if ((try self.peek()).tag == .where) {
            _ = try self.take();
        }
        try self.expect(.left_brace);
        const root = try self.addGroup();
        self.query.root_group = root;
        self.current_group = root;
        try self.parseBasicGraphPattern();
        try self.expect(.right_brace);
    }

    fn parseDatasetClauses(self: *Parser) ParseError!void {
        while ((try self.peek()).tag == .from) {
            _ = try self.take();
            var named = false;
            if ((try self.peek()).tag == .named) {
                _ = try self.take();
                named = true;
            }
            const source = try self.take();
            const iri = switch (source.tag) {
                .iri_reference => try self.resolveIri(source.lexeme),
                .prefixed_name => try self.expandPrefixedName(source.lexeme),
                else => return error.InvalidSyntax,
            };
            try self.query.dataset_clauses.append(self.allocator, .{
                .iri = iri,
                .named = named,
            });
        }
    }

    fn parseValuesClause(self: *Parser) ParseError!ValuesId {
        try self.expect(.values_keyword);
        var variables: std.ArrayList([]const u8) = .empty;
        defer variables.deinit(self.allocator);
        if ((try self.peek()).tag == .variable) {
            const variable = try self.take();
            try variables.append(self.allocator, try self.query.own(variable.lexeme));
        } else {
            try self.expect(.left_parenthesis);
            while ((try self.peek()).tag != .right_parenthesis) {
                const variable = try self.take();
                if (variable.tag != .variable or stringSliceContains(variables.items, variable.lexeme)) {
                    return error.InvalidSyntax;
                }
                try variables.append(self.allocator, try self.query.own(variable.lexeme));
            }
            try self.expect(.right_parenthesis);
        }

        try self.expect(.left_brace);
        var cells: std.ArrayList(DataValue) = .empty;
        defer cells.deinit(self.allocator);
        var row_count: usize = 0;
        if (variables.items.len == 1) {
            while ((try self.peek()).tag != .right_brace) {
                try cells.append(self.allocator, try self.parseDataValue());
                row_count += 1;
            }
        } else {
            while ((try self.peek()).tag != .right_brace) {
                try self.expect(.left_parenthesis);
                for (0..variables.items.len) |_| {
                    try cells.append(self.allocator, try self.parseDataValue());
                }
                try self.expect(.right_parenthesis);
                row_count += 1;
            }
        }
        try self.expect(.right_brace);

        const owned_variables = try variables.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_variables);
        const owned_cells = try cells.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_cells);
        const id = self.query.values_blocks.items.len;
        try self.query.values_blocks.append(self.allocator, .{
            .variables = owned_variables,
            .cells = owned_cells,
            .row_count = row_count,
        });
        return id;
    }

    fn parseDataValue(self: *Parser) ParseError!DataValue {
        const token = try self.take();
        if (token.tag == .undef) return .undefined;
        const term = try self.parseGraphTermToken(token);
        return switch (term) {
            .iri, .literal => .{ .term = term },
            else => error.InvalidSyntax,
        };
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

    fn parseProjectionExpression(
        self: *Parser,
        items: *std.ArrayList(ProjectionItem),
    ) ParseError!void {
        try self.expect(.left_parenthesis);
        const expression_id = try self.parseExpression();
        try self.expect(.as);
        const alias = try self.take();
        if (alias.tag != .variable) return error.InvalidSyntax;
        if (projectionHasVariable(items.items, alias.lexeme)) return error.InvalidSyntax;
        try self.expect(.right_parenthesis);
        try items.append(self.allocator, .{ .expression = .{
            .expression = expression_id,
            .alias = try self.query.own(alias.lexeme),
        } });
    }

    fn parseExpression(self: *Parser) ParseError!ExpressionId {
        return self.parseConditionalOrExpression();
    }

    fn parseConditionalOrExpression(self: *Parser) ParseError!ExpressionId {
        var left = try self.parseConditionalAndExpression();
        while ((try self.peek()).tag == .logical_or) {
            _ = try self.take();
            left = try self.addExpression(.{ .binary = .{
                .operator = .logical_or,
                .left = left,
                .right = try self.parseConditionalAndExpression(),
            } });
        }
        return left;
    }

    fn parseConditionalAndExpression(self: *Parser) ParseError!ExpressionId {
        var left = try self.parseRelationalExpression();
        while ((try self.peek()).tag == .logical_and) {
            _ = try self.take();
            left = try self.addExpression(.{ .binary = .{
                .operator = .logical_and,
                .left = left,
                .right = try self.parseRelationalExpression(),
            } });
        }
        return left;
    }

    fn parseRelationalExpression(self: *Parser) ParseError!ExpressionId {
        const left = try self.parseAdditiveExpression();
        const operator: ?BinaryOperator = switch ((try self.peek()).tag) {
            .equals => .equal,
            .not_equals => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            else => null,
        };
        if (operator) |value| {
            _ = try self.take();
            return self.addExpression(.{ .binary = .{
                .operator = value,
                .left = left,
                .right = try self.parseAdditiveExpression(),
            } });
        }

        var negated = false;
        if ((try self.peek()).tag == .not) {
            _ = try self.take();
            negated = true;
            try self.expect(.in);
        } else if ((try self.peek()).tag == .in) {
            _ = try self.take();
        } else {
            return left;
        }

        try self.expect(.left_parenthesis);
        var values: std.ArrayList(ExpressionId) = .empty;
        defer values.deinit(self.allocator);
        if ((try self.peek()).tag != .right_parenthesis) {
            while (true) {
                try values.append(self.allocator, try self.parseExpression());
                if ((try self.peek()).tag != .comma) break;
                _ = try self.take();
            }
        }
        try self.expect(.right_parenthesis);
        const start = self.query.expression_arguments.items.len;
        try self.query.expression_arguments.appendSlice(self.allocator, values.items);
        return self.addExpression(.{ .membership = .{
            .operand = left,
            .values = .{ .start = start, .len = values.items.len },
            .negated = negated,
        } });
    }

    fn parseAdditiveExpression(self: *Parser) ParseError!ExpressionId {
        var left = try self.parseMultiplicativeExpression();
        while (true) {
            if (isSignedNumericToken(try self.peek())) {
                left = try self.addExpression(.{ .binary = .{
                    .operator = .add,
                    .left = left,
                    .right = try self.parseSignedMultiplicativeExpression(),
                } });
                continue;
            }
            const operator: BinaryOperator = switch ((try self.peek()).tag) {
                .plus => .add,
                .minus => .subtract,
                else => return left,
            };
            _ = try self.take();
            left = try self.addExpression(.{ .binary = .{
                .operator = operator,
                .left = left,
                .right = try self.parseMultiplicativeExpression(),
            } });
        }
    }

    fn parseSignedMultiplicativeExpression(self: *Parser) ParseError!ExpressionId {
        const token = try self.take();
        var left = switch (token.tag) {
            .integer => try self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_integer),
            }),
            .decimal => try self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_decimal),
            }),
            .double => try self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_double),
            }),
            else => return error.InvalidSyntax,
        };
        while (true) {
            const operator: BinaryOperator = switch ((try self.peek()).tag) {
                .star => .multiply,
                .slash => .divide,
                else => return left,
            };
            _ = try self.take();
            left = try self.addExpression(.{ .binary = .{
                .operator = operator,
                .left = left,
                .right = try self.parseUnaryExpression(),
            } });
        }
    }

    fn parseMultiplicativeExpression(self: *Parser) ParseError!ExpressionId {
        var left = try self.parseUnaryExpression();
        while (true) {
            const operator: BinaryOperator = switch ((try self.peek()).tag) {
                .star => .multiply,
                .slash => .divide,
                else => return left,
            };
            _ = try self.take();
            left = try self.addExpression(.{ .binary = .{
                .operator = operator,
                .left = left,
                .right = try self.parseUnaryExpression(),
            } });
        }
    }

    fn parseUnaryExpression(self: *Parser) ParseError!ExpressionId {
        if ((try self.peek()).tag == .not) {
            _ = try self.take();
            try self.expect(.exists);
            return self.parseExistsExpression(true);
        }
        const operator: ?UnaryOperator = switch ((try self.peek()).tag) {
            .plus => .plus,
            .minus => .minus,
            .bang => .logical_not,
            else => null,
        };
        if (operator) |value| {
            _ = try self.take();
            return self.addExpression(.{ .unary = .{
                .operator = value,
                .operand = try self.parseUnaryExpression(),
            } });
        }
        return self.parsePrimaryExpression();
    }

    fn parsePrimaryExpression(self: *Parser) ParseError!ExpressionId {
        const token = try self.take();
        return switch (token.tag) {
            .variable => self.addExpression(.{
                .variable = try self.query.own(token.lexeme),
            }),
            .iri_reference, .prefixed_name => primary: {
                const iri = if (token.tag == .iri_reference)
                    try self.resolveIri(token.lexeme)
                else
                    try self.expandPrefixedName(token.lexeme);
                if ((try self.peek()).tag == .left_parenthesis) {
                    break :primary try self.parseFunctionCall(iri, false);
                }
                break :primary try self.addExpression(.{ .iri = iri });
            },
            .identifier => primary: {
                if (!isBuiltinFunction(token.lexeme) or
                    (try self.peek()).tag != .left_parenthesis)
                {
                    return error.InvalidSyntax;
                }
                break :primary try self.parseFunctionCall(
                    try self.ownLowercase(token.lexeme),
                    true,
                );
            },
            .string_literal => self.addExpression(.{
                .literal = try self.parseStringLiteral(token.lexeme),
            }),
            .integer => self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_integer),
            }),
            .decimal => self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_decimal),
            }),
            .double => self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_double),
            }),
            .boolean => self.addExpression(.{
                .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_namespace ++ "boolean"),
            }),
            .left_parenthesis => grouped: {
                const expression_id = try self.parseExpression();
                try self.expect(.right_parenthesis);
                break :grouped expression_id;
            },
            .exists => self.parseExistsExpression(false),
            else => error.InvalidSyntax,
        };
    }

    fn parseExistsExpression(self: *Parser, negated: bool) ParseError!ExpressionId {
        return self.addExpression(.{ .exists = .{
            .group = try self.parseBracedGroup(),
            .negated = negated,
        } });
    }

    fn parseFunctionCall(
        self: *Parser,
        function: []const u8,
        builtin: bool,
    ) ParseError!ExpressionId {
        try self.expect(.left_parenthesis);
        var arguments: std.ArrayList(ExpressionId) = .empty;
        defer arguments.deinit(self.allocator);
        var distinct = false;
        if ((try self.peek()).tag == .distinct) {
            _ = try self.take();
            distinct = true;
        }

        if ((try self.peek()).tag == .star) {
            _ = try self.take();
            try arguments.append(self.allocator, try self.addExpression(.wildcard));
        } else if ((try self.peek()).tag != .right_parenthesis) {
            while (true) {
                try arguments.append(self.allocator, try self.parseExpression());
                if ((try self.peek()).tag != .comma) break;
                _ = try self.take();
            }
        }

        var separator: ?ExpressionId = null;
        if ((try self.peek()).tag == .semicolon) {
            _ = try self.take();
            try self.expect(.separator);
            try self.expect(.equals);
            const value = try self.take();
            if (value.tag != .string_literal) return error.InvalidSyntax;
            separator = try self.addExpression(.{
                .literal = .{
                    .lexical_form = try self.decodeString(value.lexeme),
                    .datatype = rdf_mod.xsd_string,
                },
            });
        }
        try self.expect(.right_parenthesis);
        if (!self.validFunctionCall(function, builtin, arguments.items, distinct, separator)) {
            return error.InvalidSyntax;
        }

        const start = self.query.expression_arguments.items.len;
        try self.query.expression_arguments.appendSlice(self.allocator, arguments.items);
        return self.addExpression(.{ .call = .{
            .function = function,
            .arguments = .{ .start = start, .len = arguments.items.len },
            .distinct = distinct,
            .separator = separator,
        } });
    }

    fn addExpression(self: *Parser, expression: Expression) ParseError!ExpressionId {
        const id = self.query.expressions.items.len;
        try self.query.expressions.append(self.allocator, expression);
        return id;
    }

    fn validFunctionCall(
        self: *const Parser,
        function: []const u8,
        builtin: bool,
        arguments: []const ExpressionId,
        distinct: bool,
        separator: ?ExpressionId,
    ) bool {
        const wildcard = arguments.len == 1 and
            self.query.expressions.items[arguments[0]] == .wildcard;
        if (!builtin) return !wildcard and separator == null;
        if (isAggregateFunction(function)) {
            if (arguments.len != 1) return false;
            if (wildcard and !std.mem.eql(u8, function, "count")) return false;
            if (separator != null and !std.mem.eql(u8, function, "group_concat")) return false;
            return true;
        }
        if (distinct or wildcard or separator != null) return false;
        return switch (builtinSignature(function) orelse return false) {
            .zero => arguments.len == 0,
            .unary => arguments.len == 1,
            .binary => arguments.len == 2,
            .ternary => arguments.len == 3,
            .zero_or_one => arguments.len <= 1,
            .any => true,
            .two_or_three => arguments.len == 2 or arguments.len == 3,
            .three_or_four => arguments.len == 3 or arguments.len == 4,
            .bound_variable => arguments.len == 1 and
                self.query.expressions.items[arguments[0]] == .variable,
        };
    }

    fn parseBasicGraphPattern(self: *Parser) ParseError!void {
        while (true) {
            if ((try self.peek()).tag == .right_brace) return;
            if ((try self.peek()).tag == .select) {
                const group_id = self.current_group orelse return error.InvalidSyntax;
                if (self.query.groups.items[group_id].elements.items.len != 0) {
                    return error.InvalidSyntax;
                }
                try self.parseSubquery();
                if ((try self.peek()).tag != .right_brace) return error.InvalidSyntax;
                return;
            }
            if ((try self.peek()).tag == .values_keyword) {
                try self.appendGroupElement(.{ .values = try self.parseValuesClause() });
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .left_brace) {
                try self.parseNestedOrUnionGroup();
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .optional) {
                _ = try self.take();
                try self.appendGroupElement(.{ .optional = try self.parseBracedGroup() });
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .minus_keyword) {
                _ = try self.take();
                try self.appendGroupElement(.{ .minus = try self.parseBracedGroup() });
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .graph_keyword) {
                _ = try self.take();
                const selector = try self.parseGraphSelector();
                try self.appendGroupElement(.{ .graph = .{
                    .selector = selector,
                    .group = try self.parseBracedGroup(),
                } });
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .service) {
                _ = try self.take();
                var silent = false;
                if ((try self.peek()).tag == .silent) {
                    _ = try self.take();
                    silent = true;
                }
                const selector = try self.parseGraphSelector();
                try self.appendGroupElement(.{ .service = .{
                    .selector = selector,
                    .group = try self.parseBracedGroup(),
                    .silent = silent,
                } });
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .filter) {
                try self.parseFilter();
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }
            if ((try self.peek()).tag == .bind) {
                try self.parseBind();
                if ((try self.peek()).tag == .dot) _ = try self.take();
                continue;
            }

            const subject = try self.parseGraphNode();
            if (canStartPredicate((try self.peek()).tag)) {
                try self.parsePropertyList(subject.term, .right_brace);
            } else if (!subject.standalone) {
                return error.InvalidSyntax;
            }
            const separator = try self.peek();
            if (separator.tag == .right_brace) return;
            if (separator.tag == .dot) {
                _ = try self.take();
            } else if (!canStartGroupNonTriple(separator.tag)) {
                return error.InvalidSyntax;
            }
        }
    }

    fn parseGraphSelector(self: *Parser) ParseError!GraphSelector {
        const token = try self.take();
        return switch (token.tag) {
            .variable => .{ .variable = try self.query.own(token.lexeme) },
            .iri_reference => .{ .iri = try self.resolveIri(token.lexeme) },
            .prefixed_name => .{ .iri = try self.expandPrefixedName(token.lexeme) },
            else => error.InvalidSyntax,
        };
    }

    fn parseSubquery(self: *Parser) ParseError!void {
        var projection_variables: std.ArrayList([]const u8) = .empty;
        defer projection_variables.deinit(self.allocator);
        var projection_items: std.ArrayList(ProjectionItem) = .empty;
        defer projection_items.deinit(self.allocator);
        var modifier: Modifier = .none;
        var select_all = false;

        try self.parseSelectClause(.{
            .modifier = &modifier,
            .select_all = &select_all,
            .variables = &projection_variables,
            .items = &projection_items,
        });
        if ((try self.peek()).tag == .where) _ = try self.take();
        try self.expect(.left_brace);

        const group_id = try self.addGroup();
        const parent = self.current_group;
        self.current_group = group_id;
        defer self.current_group = parent;
        try self.parseBasicGraphPattern();
        try self.expect(.right_brace);
        const solution = try self.parseSolutionModifiers();
        const trailing_values = if ((try self.peek()).tag == .values_keyword)
            try self.parseValuesClause()
        else
            null;
        if (!self.projectionAliasesAreValid(
            projection_items.items,
            group_id,
            solution.group_by,
            trailing_values,
        )) {
            return error.InvalidSyntax;
        }
        if (!self.groupAliasesAreValid(solution.group_by, group_id, trailing_values)) {
            return error.InvalidSyntax;
        }
        if (!self.groupedProjectionIsValid(
            projection_items.items,
            select_all,
            solution.group_by,
            trailing_values,
        )) return error.InvalidSyntax;

        const variables = try projection_variables.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variables);
        const items = try projection_items.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(items);
        const subquery_id = self.query.subqueries.items.len;
        try self.query.groups.items[parent.?].elements.append(
            self.allocator,
            .{ .subquery = subquery_id },
        );
        try self.query.subqueries.append(self.allocator, .{
            .modifier = modifier,
            .select_all = select_all,
            .projection_variables = variables,
            .projection_items = items,
            .group = group_id,
            .solution = solution,
            .trailing_values = trailing_values,
        });
    }

    fn parseNestedOrUnionGroup(self: *Parser) ParseError!void {
        var left = try self.parseBracedGroup();
        while ((try self.peek()).tag == .union_keyword) {
            _ = try self.take();
            const right = try self.parseBracedGroup();
            const combined = try self.addGroup();
            try self.query.groups.items[combined].elements.append(
                self.allocator,
                .{ .union_group = .{ .left = left, .right = right } },
            );
            left = combined;
        }
        try self.appendGroupElement(.{ .group = left });
    }

    fn parseBracedGroup(self: *Parser) ParseError!GroupId {
        try self.expect(.left_brace);
        const group_id = try self.addGroup();
        const parent = self.current_group;
        self.current_group = group_id;
        errdefer self.current_group = parent;
        try self.parseBasicGraphPattern();
        try self.expect(.right_brace);
        self.current_group = parent;
        return group_id;
    }

    fn parseFilter(self: *Parser) ParseError!void {
        try self.expect(.filter);
        const bracketed = (try self.peek()).tag == .left_parenthesis;
        const expression_id = try self.parseExpression();
        if (!bracketed and self.query.expressions.items[expression_id] != .call and
            self.query.expressions.items[expression_id] != .exists)
        {
            return error.InvalidSyntax;
        }
        try self.appendGroupElement(.{
            .filter = expression_id,
        });
    }

    fn parseBind(self: *Parser) ParseError!void {
        try self.expect(.bind);
        try self.expect(.left_parenthesis);
        const expression_id = try self.parseExpression();
        try self.expect(.as);
        const variable = try self.take();
        if (variable.tag != .variable or self.groupHasVariable(variable.lexeme)) {
            return error.InvalidSyntax;
        }
        try self.expect(.right_parenthesis);
        try self.appendGroupElement(.{ .bind = .{
            .expression = expression_id,
            .variable = try self.query.own(variable.lexeme),
        } });
    }

    fn groupHasVariable(self: *const Parser, name: []const u8) bool {
        const group_id = self.current_group orelse return false;
        return self.groupContainsVariable(group_id, name);
    }

    fn groupContainsVariable(
        self: *const Parser,
        group_id: GroupId,
        name: []const u8,
    ) bool {
        for (self.query.groups.items[group_id].elements.items) |element| {
            switch (element) {
                .triple => |index| {
                    const triple = self.query.where_patterns.items[index];
                    if (termIsVariable(triple.subject, name) or
                        termIsVariable(triple.predicate, name) or
                        termIsVariable(triple.object, name))
                    {
                        return true;
                    }
                },
                .bind => |binding| if (std.mem.eql(u8, binding.variable, name)) return true,
                .group => |nested| if (self.groupContainsVariable(nested, name)) return true,
                .optional => |nested| if (self.groupContainsVariable(nested, name)) return true,
                .union_group => |branches| if (self.groupContainsVariable(branches.left, name) or
                    self.groupContainsVariable(branches.right, name)) return true,
                .graph => |pattern| if (selectorIsVariable(pattern.selector, name) or
                    self.groupContainsVariable(pattern.group, name)) return true,
                .service => |pattern| if (selectorIsVariable(pattern.selector, name) or
                    self.groupContainsVariable(pattern.group, name)) return true,
                .subquery => |id| if (projectionHasVariable(
                    self.query.subqueries.items[id].projection_items,
                    name,
                )) return true,
                .values => |id| if (stringSliceContains(
                    self.query.values_blocks.items[id].variables,
                    name,
                )) return true,
                else => {},
            }
        }
        return false;
    }

    fn projectionAliasesAreValid(
        self: *const Parser,
        items: []const ProjectionItem,
        group_id: GroupId,
        group_by: SolutionRange,
        trailing_values: ?ValuesId,
    ) bool {
        for (items) |item| switch (item) {
            .expression => |value| {
                if (self.groupContainsVariable(group_id, value.alias)) return false;
                const grouped = self.query.groupConditions(group_by) orelse return false;
                for (grouped) |condition| {
                    if (condition.alias) |alias| {
                        if (std.mem.eql(u8, alias, value.alias)) return false;
                    }
                }
                if (trailing_values) |id| {
                    if (stringSliceContains(
                        self.query.values_blocks.items[id].variables,
                        value.alias,
                    )) return false;
                }
            },
            .variable => {},
        };
        return true;
    }

    fn groupAliasesAreValid(
        self: *const Parser,
        group_by: SolutionRange,
        group_id: GroupId,
        trailing_values: ?ValuesId,
    ) bool {
        const grouped = self.query.groupConditions(group_by) orelse return false;
        for (grouped) |condition| {
            const alias = condition.alias orelse continue;
            if (self.groupContainsVariable(group_id, alias)) return false;
            if (trailing_values) |id| {
                if (stringSliceContains(self.query.values_blocks.items[id].variables, alias)) {
                    return false;
                }
            }
        }
        return true;
    }

    fn groupedProjectionIsValid(
        self: *const Parser,
        items: []const ProjectionItem,
        select_all: bool,
        group_by: SolutionRange,
        trailing_values: ?ValuesId,
    ) bool {
        if (group_by.len == 0) return true;
        if (select_all) return false;
        const grouped = rangeSlice(
            GroupCondition,
            self.query.group_conditions.items,
            group_by,
        ) orelse return false;
        for (items) |item| switch (item) {
            .variable => |name| {
                if (!self.groupScopeContainsVariable(grouped, trailing_values, name)) return false;
            },
            .expression => |value| if (!self.expressionIsGroupScoped(
                value.expression,
                grouped,
                trailing_values,
            )) return false,
        };
        return true;
    }

    fn expressionIsGroupScoped(
        self: *const Parser,
        expression_id: ExpressionId,
        grouped: []const GroupCondition,
        trailing_values: ?ValuesId,
    ) bool {
        return switch (self.query.expressions.items[expression_id]) {
            .variable => |name| self.groupScopeContainsVariable(grouped, trailing_values, name),
            .unary => |value| self.expressionIsGroupScoped(
                value.operand,
                grouped,
                trailing_values,
            ),
            .binary => |value| self.expressionIsGroupScoped(
                value.left,
                grouped,
                trailing_values,
            ) and self.expressionIsGroupScoped(value.right, grouped, trailing_values),
            .membership => |value| scoped: {
                if (!self.expressionIsGroupScoped(value.operand, grouped, trailing_values)) {
                    break :scoped false;
                }
                for (self.query.expressionArguments(value.values).?) |argument| {
                    if (!self.expressionIsGroupScoped(argument, grouped, trailing_values)) {
                        break :scoped false;
                    }
                }
                break :scoped true;
            },
            .call => |value| scoped: {
                if (isAggregateFunction(value.function)) break :scoped true;
                for (self.query.expressionArguments(value.arguments).?) |argument| {
                    if (!self.expressionIsGroupScoped(argument, grouped, trailing_values)) {
                        break :scoped false;
                    }
                }
                break :scoped true;
            },
            .iri, .literal, .wildcard, .exists => true,
        };
    }

    fn groupScopeContainsVariable(
        self: *const Parser,
        grouped: []const GroupCondition,
        trailing_values: ?ValuesId,
        name: []const u8,
    ) bool {
        for (grouped) |condition| {
            if (condition.alias) |alias| {
                if (std.mem.eql(u8, alias, name)) return true;
            }
            switch (self.query.expressions.items[condition.expression]) {
                .variable => |grouped_name| if (std.mem.eql(u8, grouped_name, name)) return true,
                else => {},
            }
        }
        if (trailing_values) |id| {
            return stringSliceContains(self.query.values_blocks.items[id].variables, name);
        }
        return false;
    }

    fn parsePropertyList(
        self: *Parser,
        subject: PatternTerm,
        terminator: TokenTag,
    ) ParseError!void {
        if (!canStartPredicate((try self.peek()).tag)) return error.InvalidSyntax;
        while (true) {
            const predicate = try self.parsePredicate();
            try self.parseObjectList(subject, predicate);

            var saw_semicolon = false;
            while ((try self.peek()).tag == .semicolon) {
                _ = try self.take();
                saw_semicolon = true;
            }
            if (!saw_semicolon) return;
            const next = (try self.peek()).tag;
            if (canStartPredicate(next)) continue;
            if (next == terminator or next == .dot) return;
            return error.InvalidSyntax;
        }
    }

    fn parseObjectList(
        self: *Parser,
        subject: PatternTerm,
        predicate: PatternTerm,
    ) ParseError!void {
        while (true) {
            const object = (try self.parseGraphNode()).term;
            try self.appendTriple(.{
                .subject = subject,
                .predicate = predicate,
                .object = object,
            });
            if ((try self.peek()).tag != .comma) return;
            _ = try self.take();
        }
    }

    fn parseGraphNode(self: *Parser) ParseError!ParsedGraphNode {
        const token = try self.take();
        return switch (token.tag) {
            .left_bracket => self.parseBlankNodePropertyList(),
            .left_parenthesis => self.parseCollection(),
            else => .{ .term = try self.parseGraphTermToken(token) },
        };
    }

    fn parseGraphTermToken(self: *Parser, token: Token) ParseError!PatternTerm {
        return switch (token.tag) {
            .variable => .{ .variable = try self.query.own(token.lexeme) },
            .iri_reference => .{ .iri = try self.resolveIri(token.lexeme) },
            .prefixed_name => .{ .iri = try self.expandPrefixedName(token.lexeme) },
            .blank_node_label => .{ .blank_node = .{
                .labeled = try self.query.own(token.lexeme[2..]),
            } },
            .string_literal => .{ .literal = try self.parseStringLiteral(token.lexeme) },
            .integer => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_integer) },
            .decimal => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_decimal) },
            .double => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_double) },
            .boolean => .{ .literal = try self.numericLiteral(token.lexeme, rdf_mod.xsd_namespace ++ "boolean") },
            else => error.InvalidSyntax,
        };
    }

    fn parsePredicate(self: *Parser) ParseError!PatternTerm {
        if ((try self.peek()).tag == .variable) {
            const token = try self.take();
            return .{ .variable = try self.query.own(token.lexeme) };
        }
        const path_id = try self.parsePathAlternative();
        return switch (self.query.paths.items[path_id]) {
            .iri => |value| .{ .iri = value },
            else => .{ .path = path_id },
        };
    }

    fn parsePathAlternative(self: *Parser) ParseError!PathId {
        var left = try self.parsePathSequence();
        while ((try self.peek()).tag == .pipe) {
            _ = try self.take();
            const right = try self.parsePathSequence();
            left = try self.addPath(.{ .alternative = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parsePathSequence(self: *Parser) ParseError!PathId {
        var left = try self.parsePathEltOrInverse();
        while ((try self.peek()).tag == .slash) {
            _ = try self.take();
            const right = try self.parsePathEltOrInverse();
            left = try self.addPath(.{ .sequence = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parsePathEltOrInverse(self: *Parser) ParseError!PathId {
        if ((try self.peek()).tag == .caret) {
            _ = try self.take();
            return self.addPath(.{ .inverse = try self.parsePathElt() });
        }
        return self.parsePathElt();
    }

    fn parsePathElt(self: *Parser) ParseError!PathId {
        var path_id = try self.parsePathPrimary();
        path_id = switch ((try self.peek()).tag) {
            .star => modified: {
                _ = try self.take();
                break :modified try self.addPath(.{ .zero_or_more = path_id });
            },
            .plus => modified: {
                _ = try self.take();
                break :modified try self.addPath(.{ .one_or_more = path_id });
            },
            .question => modified: {
                _ = try self.take();
                break :modified try self.addPath(.{ .zero_or_one = path_id });
            },
            else => path_id,
        };
        return path_id;
    }

    fn parsePathPrimary(self: *Parser) ParseError!PathId {
        const token = try self.take();
        return switch (token.tag) {
            .iri_reference, .prefixed_name, .keyword_a => self.addPath(.{
                .iri = try self.resolvePathIri(token),
            }),
            .left_parenthesis => grouped: {
                const path_id = try self.parsePathAlternative();
                try self.expect(.right_parenthesis);
                break :grouped path_id;
            },
            .bang => self.parseNegatedPropertySet(),
            else => error.InvalidSyntax,
        };
    }

    fn parseNegatedPropertySet(self: *Parser) ParseError!PathId {
        const start = self.query.negated_properties.items.len;
        if ((try self.peek()).tag == .left_parenthesis) {
            _ = try self.take();
            if ((try self.peek()).tag != .right_parenthesis) {
                while (true) {
                    try self.parseNegatedProperty();
                    if ((try self.peek()).tag != .pipe) break;
                    _ = try self.take();
                }
            }
            try self.expect(.right_parenthesis);
        } else {
            try self.parseNegatedProperty();
        }
        return self.addPath(.{ .negated_property_set = .{
            .start = start,
            .len = self.query.negated_properties.items.len - start,
        } });
    }

    fn parseNegatedProperty(self: *Parser) ParseError!void {
        var inverse = false;
        if ((try self.peek()).tag == .caret) {
            _ = try self.take();
            inverse = true;
        }
        const token = try self.take();
        if (token.tag != .iri_reference and token.tag != .prefixed_name and
            token.tag != .keyword_a)
        {
            return error.InvalidSyntax;
        }
        try self.query.negated_properties.append(self.allocator, .{
            .iri = try self.resolvePathIri(token),
            .inverse = inverse,
        });
    }

    fn resolvePathIri(self: *Parser, token: Token) ParseError![]const u8 {
        return switch (token.tag) {
            .iri_reference => self.resolveIri(token.lexeme),
            .prefixed_name => self.expandPrefixedName(token.lexeme),
            .keyword_a => rdf_mod.rdf_namespace ++ "type",
            else => error.InvalidSyntax,
        };
    }

    fn addPath(self: *Parser, path: Path) ParseError!PathId {
        const id = self.query.paths.items.len;
        try self.query.paths.append(self.allocator, path);
        return id;
    }

    fn freshAnonymousBlankNode(self: *Parser) PatternTerm {
        const id = self.query.next_blank_node;
        self.query.next_blank_node += 1;
        return .{ .blank_node = .{ .anonymous = id } };
    }

    fn parseBlankNodePropertyList(self: *Parser) ParseError!ParsedGraphNode {
        const node = self.freshAnonymousBlankNode();
        if ((try self.peek()).tag == .right_bracket) {
            _ = try self.take();
            return .{ .term = node };
        }
        try self.parsePropertyList(node, .right_bracket);
        try self.expect(.right_bracket);
        return .{ .term = node, .standalone = true };
    }

    fn parseCollection(self: *Parser) ParseError!ParsedGraphNode {
        if ((try self.peek()).tag == .right_parenthesis) {
            _ = try self.take();
            return .{
                .term = .{ .iri = rdf_mod.rdf_namespace ++ "nil" },
                .standalone = true,
            };
        }

        const head = self.freshAnonymousBlankNode();
        var current = head;
        while (true) {
            const item = (try self.parseGraphNode()).term;
            try self.appendTriple(.{
                .subject = current,
                .predicate = .{ .iri = rdf_mod.rdf_namespace ++ "first" },
                .object = item,
            });

            if ((try self.peek()).tag == .right_parenthesis) {
                _ = try self.take();
                try self.appendTriple(.{
                    .subject = current,
                    .predicate = .{ .iri = rdf_mod.rdf_namespace ++ "rest" },
                    .object = .{ .iri = rdf_mod.rdf_namespace ++ "nil" },
                });
                return .{ .term = head, .standalone = true };
            }

            const tail = self.freshAnonymousBlankNode();
            try self.appendTriple(.{
                .subject = current,
                .predicate = .{ .iri = rdf_mod.rdf_namespace ++ "rest" },
                .object = tail,
            });
            current = tail;
        }
    }

    fn appendTriple(self: *Parser, triple: TriplePattern) ParseError!void {
        const index = self.query.where_patterns.items.len;
        try self.query.where_patterns.append(self.allocator, triple);
        try self.appendGroupElement(.{ .triple = index });
    }

    fn addGroup(self: *Parser) ParseError!GroupId {
        const id = self.query.groups.items.len;
        try self.query.groups.append(self.allocator, .{});
        return id;
    }

    fn appendGroupElement(self: *Parser, element: GroupElement) ParseError!void {
        const group_id = self.current_group orelse return error.InvalidSyntax;
        try self.query.groups.items[group_id].elements.append(self.allocator, element);
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

fn canStartPredicate(tag: TokenTag) bool {
    return tag == .variable or canStartPath(tag);
}

fn canStartGroupNonTriple(tag: TokenTag) bool {
    return tag == .filter or tag == .bind or tag == .left_brace or tag == .optional or
        tag == .minus_keyword or tag == .values_keyword or tag == .graph_keyword or
        tag == .service;
}

fn selectorIsVariable(selector: GraphSelector, name: []const u8) bool {
    return switch (selector) {
        .variable => |variable| std.mem.eql(u8, variable, name),
        .iri => false,
    };
}

fn canStartGroupCondition(tag: TokenTag) bool {
    return tag == .variable or tag == .left_parenthesis or tag == .identifier or
        tag == .iri_reference or tag == .prefixed_name;
}

fn canStartConstraint(tag: TokenTag) bool {
    return tag == .left_parenthesis or tag == .identifier or tag == .iri_reference or
        tag == .prefixed_name or tag == .exists or tag == .not;
}

fn canStartOrderCondition(tag: TokenTag) bool {
    return canStartConstraint(tag) or tag == .variable or tag == .ascending or
        tag == .descending;
}

fn rangeSlice(comptime T: type, items: []const T, range: SolutionRange) ?[]const T {
    if (range.start > items.len or range.len > items.len - range.start) return null;
    return items[range.start..][0..range.len];
}

fn stringSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn projectionHasVariable(items: []const ProjectionItem, name: []const u8) bool {
    for (items) |item| {
        const variable = switch (item) {
            .variable => |value| value,
            .expression => |value| value.alias,
        };
        if (std.mem.eql(u8, variable, name)) return true;
    }
    return false;
}

fn termIsVariable(term: PatternTerm, name: []const u8) bool {
    return switch (term) {
        .variable => |variable| std.mem.eql(u8, variable, name),
        else => false,
    };
}

fn canStartPath(tag: TokenTag) bool {
    return tag == .iri_reference or tag == .prefixed_name or tag == .keyword_a or
        tag == .caret or tag == .bang or tag == .left_parenthesis;
}

const BuiltinSignature = enum {
    zero,
    unary,
    binary,
    ternary,
    zero_or_one,
    any,
    two_or_three,
    three_or_four,
    bound_variable,
};

fn isBuiltinFunction(value: []const u8) bool {
    return builtinSignature(value) != null or isAggregateFunction(value);
}

fn builtinSignature(value: []const u8) ?BuiltinSignature {
    const unary = [_][]const u8{
        "str",    "lang",    "datatype",       "iri",       "uri",
        "abs",    "ceil",    "floor",          "round",     "isiri",
        "isuri",  "isblank", "isliteral",      "isnumeric", "strlen",
        "ucase",  "lcase",   "encode_for_uri", "year",      "month",
        "day",    "hours",   "minutes",        "seconds",   "timezone",
        "tz",     "md5",     "sha1",           "sha256",    "sha384",
        "sha512",
    };
    for (unary) |name| {
        if (std.ascii.eqlIgnoreCase(value, name)) return .unary;
    }
    const binary = [_][]const u8{
        "langmatches", "sameterm", "contains", "strstarts", "strends",
        "strbefore",   "strafter", "strlang",  "strdt",
    };
    for (binary) |name| {
        if (std.ascii.eqlIgnoreCase(value, name)) return .binary;
    }
    if (std.ascii.eqlIgnoreCase(value, "concat") or
        std.ascii.eqlIgnoreCase(value, "coalesce")) return .any;
    if (std.ascii.eqlIgnoreCase(value, "substr") or
        std.ascii.eqlIgnoreCase(value, "regex")) return .two_or_three;
    if (std.ascii.eqlIgnoreCase(value, "replace")) return .three_or_four;
    if (std.ascii.eqlIgnoreCase(value, "bnode")) return .zero_or_one;
    if (std.ascii.eqlIgnoreCase(value, "rand") or
        std.ascii.eqlIgnoreCase(value, "now") or
        std.ascii.eqlIgnoreCase(value, "uuid") or
        std.ascii.eqlIgnoreCase(value, "struuid")) return .zero;
    if (std.ascii.eqlIgnoreCase(value, "if")) return .ternary;
    if (std.ascii.eqlIgnoreCase(value, "bound")) return .bound_variable;
    return null;
}

fn isSignedNumericToken(token: Token) bool {
    return (token.tag == .integer or token.tag == .decimal or token.tag == .double) and
        token.lexeme.len > 1 and (token.lexeme[0] == '+' or token.lexeme[0] == '-');
}

fn isAggregateFunction(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "count") or
        std.ascii.eqlIgnoreCase(value, "sum") or
        std.ascii.eqlIgnoreCase(value, "min") or
        std.ascii.eqlIgnoreCase(value, "max") or
        std.ascii.eqlIgnoreCase(value, "avg") or
        std.ascii.eqlIgnoreCase(value, "sample") or
        std.ascii.eqlIgnoreCase(value, "group_concat");
}

fn isDelimiter(byte: u8) bool {
    return isWhitespace(byte) or byte == '#' or byte == '{' or byte == '}' or
        byte == '.' or byte == '*' or byte == '<' or byte == '>' or byte == '?' or
        byte == '$' or byte == '(' or byte == ')' or byte == '[' or byte == ']' or
        byte == ';' or byte == ',' or byte == '/' or byte == '|' or byte == '!' or
        byte == '^' or byte == '+' or byte == '-' or byte == '=' or byte == '&';
}

fn isWordDelimiter(byte: u8) bool {
    return isWhitespace(byte) or byte == '#' or byte == '{' or byte == '}' or
        byte == '*' or byte == '<' or byte == '>' or byte == '?' or byte == '$' or
        byte == '(' or byte == ')' or byte == '[' or byte == ']' or byte == ';' or
        byte == ',' or byte == '/' or byte == '|' or byte == '!' or byte == '^' or
        byte == '+' or byte == '=' or byte == '&';
}

fn isNumericExponentPrefix(value: []const u8) bool {
    if (value.len < 2 or (value[value.len - 1] != 'e' and value[value.len - 1] != 'E')) {
        return false;
    }
    var index: usize = 0;
    if (value[index] == '+' or value[index] == '-') index += 1;
    var digits: usize = 0;
    var saw_dot = false;
    while (index + 1 < value.len) : (index += 1) {
        if (std.ascii.isDigit(value[index])) {
            digits += 1;
        } else if (value[index] == '.' and !saw_dot) {
            saw_dot = true;
        } else {
            return false;
        }
    }
    return digits > 0;
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

test "expands predicate and object list shorthand" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> " ++
            "SELECT * { ex:s ex:p ex:o1, ex:o2 ; ex:q \"value\" ;; . }",
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 3), query.patterns().len);
    try std.testing.expectEqualStrings("https://example.com/o1", query.patterns()[0].object.iri);
    try std.testing.expectEqualStrings("https://example.com/o2", query.patterns()[1].object.iri);
    try std.testing.expectEqualStrings("https://example.com/q", query.patterns()[2].predicate.iri);
    try std.testing.expectEqualStrings("value", query.patterns()[2].object.literal.lexical_form);
}

test "expands blank-node property lists including standalone and nested forms" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> SELECT * { " ++
            "[ ex:p ex:o ; ex:q [ ex:r \"nested\" ] ] ex:outer ex:z . " ++
            "[ ex:standalone ex:value ] . }",
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 5), query.patterns().len);
    const outer = query.patterns()[0].subject.blank_node.anonymous;
    const nested = query.patterns()[1].subject.blank_node.anonymous;
    try std.testing.expect(outer != nested);
    try std.testing.expectEqual(nested, query.patterns()[2].object.blank_node.anonymous);
    try std.testing.expectEqual(outer, query.patterns()[3].subject.blank_node.anonymous);
    try std.testing.expectEqualStrings("https://example.com/outer", query.patterns()[3].predicate.iri);
}

test "expands RDF collections and handles rdf:nil" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> " ++
            "SELECT * { ex:s ex:items (ex:a ex:b) . ex:s ex:empty () }",
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 6), query.patterns().len);
    try std.testing.expectEqualStrings(
        rdf_mod.rdf_namespace ++ "first",
        query.patterns()[0].predicate.iri,
    );
    try std.testing.expectEqualStrings(
        rdf_mod.rdf_namespace ++ "rest",
        query.patterns()[1].predicate.iri,
    );
    try std.testing.expectEqual(
        query.patterns()[1].object.blank_node.anonymous,
        query.patterns()[2].subject.blank_node.anonymous,
    );
    try std.testing.expectEqualStrings(
        rdf_mod.rdf_namespace ++ "nil",
        query.patterns()[3].object.iri,
    );
    try std.testing.expectEqualStrings(
        rdf_mod.rdf_namespace ++ "nil",
        query.patterns()[5].object.iri,
    );
}

test "parses property-path precedence modifiers inverse and negated sets" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> SELECT * { " ++
            "?s (^ex:p/ex:q+|!(ex:r|^a))? ?o . ?s ex:z* ?o }",
    );
    defer query.deinit();

    const root_id = query.patterns()[0].predicate.path;
    const alternative_id = query.path(root_id).?.zero_or_one;
    const alternative = query.path(alternative_id).?.alternative;
    const sequence = query.path(alternative.left).?.sequence;
    try std.testing.expect(query.path(sequence.left).? == .inverse);
    try std.testing.expect(query.path(sequence.right).? == .one_or_more);

    const negated = query.path(alternative.right).?.negated_property_set;
    const properties = query.negatedPropertySet(negated).?;
    try std.testing.expectEqual(@as(usize, 2), properties.len);
    try std.testing.expectEqualStrings("https://example.com/r", properties[0].iri);
    try std.testing.expect(!properties[0].inverse);
    try std.testing.expectEqualStrings(rdf_mod.rdf_namespace ++ "type", properties[1].iri);
    try std.testing.expect(properties[1].inverse);
    try std.testing.expect(query.path(query.patterns()[1].predicate.path).? == .zero_or_more);

    const lowered = query.lower().project.input.bgp;
    try std.testing.expect(lowered.paths.len > 0);
    try std.testing.expectEqual(@as(usize, 2), lowered.negated_properties.len);
}

test "parses SELECT expression aliases with operator precedence and calls" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> " ++
            "SELECT ?x (?x + ?y * -(2) AS ?value) " ++
            "(datatype(?x) AS ?datatype) (ex:function(?x, 1) AS ?custom) " ++
            "(?x-?y AS ?difference) {}",
    );
    defer query.deinit();

    const projection = query.projection();
    try std.testing.expect(projection == .items);
    try std.testing.expectEqual(@as(usize, 5), projection.items.len);
    const root = query.expression(projection.items[1].expression.expression).?.binary;
    try std.testing.expectEqual(BinaryOperator.add, root.operator);
    const product = query.expression(root.right).?.binary;
    try std.testing.expectEqual(BinaryOperator.multiply, product.operator);
    try std.testing.expect(query.expression(product.right).? == .unary);

    const datatype_call = query.expression(projection.items[2].expression.expression).?.call;
    try std.testing.expectEqualStrings("datatype", datatype_call.function);
    try std.testing.expectEqual(@as(usize, 1), query.expressionArguments(datatype_call.arguments).?.len);
    const custom_call = query.expression(projection.items[3].expression.expression).?.call;
    try std.testing.expectEqualStrings("https://example.com/function", custom_call.function);
    try std.testing.expectEqual(@as(usize, 2), query.expressionArguments(custom_call.arguments).?.len);
    try std.testing.expectEqual(
        BinaryOperator.subtract,
        query.expression(projection.items[4].expression.expression).?.binary.operator,
    );
}

test "parses aggregate DISTINCT wildcard and GROUP_CONCAT separator syntax" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT (COUNT(DISTINCT *) AS ?count) " ++
            "(GROUP_CONCAT(DISTINCT ?x; SEPARATOR=';') AS ?joined) {}",
    );
    defer query.deinit();

    const items = query.projection().items;
    const count = query.expression(items[0].expression.expression).?.call;
    try std.testing.expect(count.distinct);
    const count_arguments = query.expressionArguments(count.arguments).?;
    try std.testing.expect(query.expression(count_arguments[0]).? == .wildcard);

    const group_concat = query.expression(items[1].expression.expression).?.call;
    try std.testing.expect(group_concat.distinct);
    try std.testing.expectEqualStrings("group_concat", group_concat.function);
    try std.testing.expectEqualStrings(
        ";",
        query.expression(group_concat.separator.?).?.literal.lexical_form,
    );
    const lowered = query.lower().project;
    try std.testing.expect(lowered.expressions.len > 0);
    try std.testing.expectEqual(@as(usize, 2), lowered.expression_arguments.len);
}

test "parses core term and numeric built-in calls with strict signatures" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT (BOUND(?x) AS ?bound) (BNODE() AS ?fresh) " ++
            "(BNODE('id') AS ?named) (RAND() AS ?random) " ++
            "(LANGMATCHES(LANG(?x), 'en') AS ?matches) " ++
            "(sameTerm(?x, ?y) AS ?same) (ABS(-1) AS ?absolute) " ++
            "(isIRI(?x) AS ?is_iri) {}",
    );
    defer query.deinit();

    const items = query.projection().items;
    try std.testing.expectEqual(@as(usize, 8), items.len);
    const bound = query.expression(items[0].expression.expression).?.call;
    try std.testing.expectEqualStrings("bound", bound.function);
    try std.testing.expectEqual(@as(usize, 1), bound.arguments.len);
    const fresh = query.expression(items[1].expression.expression).?.call;
    try std.testing.expectEqualStrings("bnode", fresh.function);
    try std.testing.expectEqual(@as(usize, 0), fresh.arguments.len);
    const named = query.expression(items[2].expression.expression).?.call;
    try std.testing.expectEqual(@as(usize, 1), named.arguments.len);
    const matches = query.expression(items[4].expression.expression).?.call;
    try std.testing.expectEqualStrings("langmatches", matches.function);
    try std.testing.expectEqual(@as(usize, 2), matches.arguments.len);
    const same = query.expression(items[5].expression.expression).?.call;
    try std.testing.expectEqualStrings("sameterm", same.function);
    try std.testing.expectEqual(@as(usize, 2), same.arguments.len);
}

test "parses string regex and RDF literal constructor built-ins" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT (CONCAT() AS ?empty) (CONCAT(?x, 'a') AS ?joined) " ++
            "(SUBSTR(?x, 2) AS ?tail) (SUBSTR(?x, 2, 3) AS ?slice) " ++
            "(REPLACE(?x, 'a', 'b', 'i') AS ?replaced) " ++
            "(REGEX(?x, '^a', 'i') AS ?matches) " ++
            "(STRLANG(?x, 'en') AS ?language) (STRDT(?x, <urn:type>) AS ?typed) " ++
            "(ENCODE_FOR_URI(UCASE(?x)) AS ?encoded) " ++
            "(CONTAINS(?x, 'a') AS ?contains) {}",
    );
    defer query.deinit();

    const items = query.projection().items;
    try std.testing.expectEqual(@as(usize, 10), items.len);
    const empty = query.expression(items[0].expression.expression).?.call;
    try std.testing.expectEqualStrings("concat", empty.function);
    try std.testing.expectEqual(@as(usize, 0), empty.arguments.len);
    const substring = query.expression(items[3].expression.expression).?.call;
    try std.testing.expectEqualStrings("substr", substring.function);
    try std.testing.expectEqual(@as(usize, 3), substring.arguments.len);
    const replacement = query.expression(items[4].expression.expression).?.call;
    try std.testing.expectEqual(@as(usize, 4), replacement.arguments.len);
    const regex = query.expression(items[5].expression.expression).?.call;
    try std.testing.expectEqual(@as(usize, 3), regex.arguments.len);
    const constructor = query.expression(items[7].expression.expression).?.call;
    try std.testing.expectEqualStrings("strdt", constructor.function);
}

test "parses temporal hash UUID and conditional built-ins" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT (YEAR(?date) AS ?year) (TIMEZONE(?date) AS ?zone) " ++
            "(NOW() AS ?now) (UUID() AS ?uuid) (STRUUID() AS ?uuid_text) " ++
            "(SHA256(?x) AS ?hash) (COALESCE() AS ?empty) " ++
            "(COALESCE(?x, 'fallback') AS ?choice) " ++
            "(IF(BOUND(?x), ?x, 'missing') AS ?conditional) {}",
    );
    defer query.deinit();

    const items = query.projection().items;
    try std.testing.expectEqual(@as(usize, 9), items.len);
    const now = query.expression(items[2].expression.expression).?.call;
    try std.testing.expectEqualStrings("now", now.function);
    try std.testing.expectEqual(@as(usize, 0), now.arguments.len);
    const hash = query.expression(items[5].expression.expression).?.call;
    try std.testing.expectEqualStrings("sha256", hash.function);
    try std.testing.expectEqual(@as(usize, 1), hash.arguments.len);
    const empty = query.expression(items[6].expression.expression).?.call;
    try std.testing.expectEqualStrings("coalesce", empty.function);
    try std.testing.expectEqual(@as(usize, 0), empty.arguments.len);
    const conditional = query.expression(items[8].expression.expression).?.call;
    try std.testing.expectEqualStrings("if", conditional.function);
    try std.testing.expectEqual(@as(usize, 3), conditional.arguments.len);
}

test "parses relational logical and membership expressions in FILTER" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { ?s ?p ?o " ++
            "FILTER((?o >= 1 && ?o < 10) || ?o != 2) " ++
            "FILTER(?o NOT IN(1, 2, ?s+57)) FILTER(?o IN()) }",
    );
    defer query.deinit();

    const elements = query.lower().project.input.bgp.elements;
    try std.testing.expectEqual(@as(usize, 4), elements.len);
    const logical = query.expression(elements[1].filter).?.binary;
    try std.testing.expectEqual(BinaryOperator.logical_or, logical.operator);
    const membership = query.expression(elements[2].filter).?.membership;
    try std.testing.expect(membership.negated);
    try std.testing.expectEqual(@as(usize, 3), query.expressionArguments(membership.values).?.len);
    const empty_membership = query.expression(elements[3].filter).?.membership;
    try std.testing.expect(!empty_membership.negated);
    try std.testing.expectEqual(@as(usize, 0), empty_membership.values.len);
}

test "preserves ordered BIND elements and validates group scope" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT ?next { ?s ?p ?o . BIND(?o+1 AS ?next) " ++
            "BIND(?next/2 AS ?half) FILTER(?half = 1) }",
    );
    defer query.deinit();

    const elements = query.lower().project.input.bgp.elements;
    try std.testing.expectEqual(@as(usize, 4), elements.len);
    try std.testing.expectEqualStrings("next", elements[1].bind.variable);
    try std.testing.expectEqualStrings("half", elements[2].bind.variable);
    try std.testing.expect(elements[3] == .filter);
}

test "preserves nested UNION OPTIONAL and MINUS group structure" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> SELECT * { " ++
            "{ ?s ex:p ?o } UNION { ?s ex:q ?o } " ++
            "OPTIONAL { ?s ex:r ?optional } MINUS { ?s ex:hidden ?value } }",
    );
    defer query.deinit();

    const root = query.lower().project.input.bgp.elements;
    try std.testing.expectEqual(@as(usize, 3), root.len);
    const union_wrapper = query.groupElements(root[0].group).?;
    try std.testing.expectEqual(@as(usize, 1), union_wrapper.len);
    const branches = union_wrapper[0].union_group;
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(branches.left).?.len);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(branches.right).?.len);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(root[1].optional).?.len);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(root[2].minus).?.len);
}

test "parses EXISTS and NOT EXISTS with query-local groups" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { ?s ?p ?o " ++
            "FILTER(EXISTS { ?s ?p ?o } && NOT EXISTS { ?s ?q ?v }) }",
    );
    defer query.deinit();

    const filter_id = query.lower().project.input.bgp.elements[1].filter;
    const conjunction = query.expression(filter_id).?.binary;
    const exists = query.expression(conjunction.left).?.exists;
    const not_exists = query.expression(conjunction.right).?.exists;
    try std.testing.expect(!exists.negated);
    try std.testing.expect(not_exists.negated);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(exists.group).?.len);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(not_exists.group).?.len);
}

test "preserves GRAPH and SERVICE selectors with nested groups" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX ex: <https://example.com/> SELECT * { " ++
            "GRAPH ?g { ?s ex:p ?o } " ++
            "SERVICE SILENT ex:endpoint { ?s ex:q ?remote } " ++
            "SERVICE ?endpoint { ?s ex:r ?value } }",
    );
    defer query.deinit();

    const elements = query.groupElements(query.root_group.?).?;
    try std.testing.expectEqual(@as(usize, 3), elements.len);
    try std.testing.expectEqualStrings("g", elements[0].graph.selector.variable);
    try std.testing.expectEqual(@as(usize, 1), query.groupElements(elements[0].graph.group).?.len);
    try std.testing.expect(elements[1].service.silent);
    try std.testing.expectEqualStrings(
        "https://example.com/endpoint",
        elements[1].service.selector.iri,
    );
    try std.testing.expect(!elements[2].service.silent);
    try std.testing.expectEqualStrings("endpoint", elements[2].service.selector.variable);
}

test "lowers SELECT syntax to project over a BGP" {
    var query = try parseQuery(std.testing.allocator, "SELECT ?s WHERE { ?s <urn:p> <urn:o> }");
    defer query.deinit();
    const lowered = query.lower();
    try std.testing.expectEqual(@as(usize, 1), lowered.project.projection.variables.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.project.input.bgp.triples.len);
}

test "parses ASK and CONSTRUCT WHERE query forms with datasets" {
    var ask = try parseQuery(std.testing.allocator, "PREFIX ex: <urn:ex:> ASK {}");
    defer ask.deinit();
    try std.testing.expectEqual(QueryForm.ask, ask.form);
    try std.testing.expectEqual(@as(usize, 0), ask.lower().ask.input.bgp.elements.len);

    var construct = try parseQuery(
        std.testing.allocator,
        "CONSTRUCT FROM <urn:default> FROM NAMED <urn:named> WHERE { ?s ?p 1816 }",
    );
    defer construct.deinit();
    try std.testing.expectEqual(QueryForm.construct, construct.form);
    try std.testing.expectEqual(@as(usize, 2), construct.datasetClauses().len);
    try std.testing.expect(!construct.datasetClauses()[0].named);
    try std.testing.expect(construct.datasetClauses()[1].named);
    try std.testing.expectEqualStrings("urn:named", construct.datasetClauses()[1].iri);
    try std.testing.expectEqual(@as(usize, 1), construct.lower().construct.input.bgp.triples.len);
}

test "preserves SELECT subqueries with independent projection scope" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { { SELECT (1 AS ?x) {} } { SELECT (2 AS ?x) {} } }",
    );
    defer query.deinit();

    const root = query.groupElements(query.root_group.?).?;
    try std.testing.expectEqual(@as(usize, 2), root.len);
    const first_group = query.groupElements(root[0].group).?;
    const second_group = query.groupElements(root[1].group).?;
    const first = query.subquery(first_group[0].subquery).?;
    const second = query.subquery(second_group[0].subquery).?;
    try std.testing.expectEqualStrings("x", first.projection().items[0].expression.alias);
    try std.testing.expectEqualStrings("x", second.projection().items[0].expression.alias);
    try std.testing.expect(first.group != second.group);
}

test "parses GROUP BY with trailing VALUES scope" {
    var query = try parseQuery(
        std.testing.allocator,
        "PREFIX : <urn:ex:> SELECT ?s (STR(?v) AS ?w) { ?s :p ?o } " ++
            "GROUP BY ?s VALUES ?v { 1 UNDEF }",
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 1), query.groupBy().len);
    try std.testing.expectEqualStrings(
        "s",
        query.expression(query.groupBy()[0].expression).?.variable,
    );
    const values = query.trailingValues().?;
    try std.testing.expectEqual(@as(usize, 1), values.variables.len);
    try std.testing.expectEqualStrings("v", values.variables[0]);
    try std.testing.expectEqual(@as(usize, 2), values.row_count);
    try std.testing.expectEqualStrings("1", values.value(0, 0).?.term.literal.lexical_form);
    try std.testing.expect(values.value(1, 0).? == .undefined);
    try std.testing.expectEqual(@as(usize, 1), query.lower().project.group_by.len);
}

test "preserves zero-arity and inline multi-variable VALUES blocks" {
    var empty = try parseQuery(std.testing.allocator, "SELECT * {} VALUES () { () }");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.trailingValues().?.variables.len);
    try std.testing.expectEqual(@as(usize, 1), empty.trailingValues().?.row_count);

    var inline_values = try parseQuery(
        std.testing.allocator,
        "SELECT * { VALUES (?x ?y) { (1 UNDEF) } }",
    );
    defer inline_values.deinit();
    const elements = inline_values.groupElements(inline_values.root_group.?).?;
    const values = inline_values.values(elements[0].values).?;
    try std.testing.expectEqual(@as(usize, 2), values.variables.len);
    try std.testing.expectEqual(@as(usize, 1), values.row_count);
    try std.testing.expect(values.value(0, 1).? == .undefined);
}

test "parses complete ordered solution modifiers" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT ?key (COUNT(*) AS ?count) { ?s ?p ?o } " ++
            "GROUP BY (?s AS ?key) " ++
            "HAVING (COUNT(*) > 1) " ++
            "ORDER BY DESC(COUNT(*)) ASC(?key) ?key " ++
            "LIMIT 10 OFFSET 2",
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 1), query.groupBy().len);
    try std.testing.expectEqualStrings("key", query.groupBy()[0].alias.?);
    try std.testing.expectEqual(@as(usize, 1), query.having().len);
    try std.testing.expectEqual(@as(usize, 3), query.orderBy().len);
    try std.testing.expectEqual(OrderDirection.descending, query.orderBy()[0].direction);
    try std.testing.expectEqual(OrderDirection.ascending, query.orderBy()[1].direction);
    try std.testing.expectEqual(OrderDirection.default, query.orderBy()[2].direction);
    try std.testing.expectEqual(@as(?usize, 10), query.solution.limit);
    try std.testing.expectEqual(@as(?usize, 2), query.solution.offset);

    const lowered = query.lower().project;
    try std.testing.expectEqual(@as(usize, 1), lowered.having.len);
    try std.testing.expectEqual(@as(usize, 3), lowered.order_by.len);
    try std.testing.expectEqual(@as(?usize, 10), lowered.limit);
    try std.testing.expectEqual(@as(?usize, 2), lowered.offset);
}

test "preserves solution modifiers on SELECT subqueries" {
    var query = try parseQuery(
        std.testing.allocator,
        "SELECT * { SELECT ?s { ?s ?p ?o } ORDER BY ?s OFFSET 3 LIMIT 1 }",
    );
    defer query.deinit();

    const root = query.groupElements(query.root_group.?).?;
    const subquery = query.subquery(root[0].subquery).?;
    const ordering = query.orderConditions(subquery.solution.order_by).?;
    try std.testing.expectEqual(@as(usize, 1), ordering.len);
    try std.testing.expectEqual(@as(?usize, 1), subquery.solution.limit);
    try std.testing.expectEqual(@as(?usize, 3), subquery.solution.offset);
}

test "rejects malformed or unsupported query syntax" {
    const invalid = [_][]const u8{
        "",                                                       "SELECT WHERE {}",                                                    "SELECT * WHERE { ?s <urn:p> }",
        "SELECT * WHERE { ?s \"literal\" ?o }",                   "ASK SELECT * {}",                                                    "SELECT * WHERE { ?s <broken iri> ?o }",
        "SELECT ?not-valid WHERE {}",                             "PREFIX ex:bad <urn:ex> SELECT * {}",                                 "PREFIX bad <urn:ex> SELECT * {}",
        "PREFIX ex: <urn:ex> SELECT * { ex:s missing:p ex:o }",   "BASE not-an-iri SELECT * {}",                                        "PREFIX ex: <urn:ex> SELECT * { ex:a%ZZ ex:p ex:o }",
        "PREFIX ex: <urn:ex> SELECT * { ex:a\\q ex:p ex:o }",     "SELECT * { ?s <urn:p> \"bad\\q\" }",                                 "SELECT * { ?s <urn:p> \"unterminated }",
        "SELECT * { ?s <urn:p> \"value\"@en--US }",               "SELECT * { ?s <urn:p> \"value\"^^_:datatype }",                      "SELECT * { _:trailing. <urn:p> <urn:o> }",
        "SELECT * { ?s <urn:p> \"\\uD800\" }",                    "SELECT * { ?s <urn:\\U00110000> ?o }",                               "SELECT * { ?s <urn:p> <urn:o>, }",
        "SELECT * { ?s ; <urn:p> <urn:o> }",                      "SELECT * { [] }",                                                    "SELECT * { ?s <urn:p> ( <urn:a> }",
        "SELECT * { [ <urn:p> <urn:o> }",                         "SELECT * { ?s <urn:p>/ ?o }",                                        "SELECT * { ?s <urn:p>** ?o }",
        "SELECT * { ?s ^ ?o }",                                   "SELECT * { ?s !(<urn:p>/<urn:q>) ?o }",                              "SELECT * { ?s ?p* ?o }",
        "SELECT * { ?s () ?o }",                                  "SELECT * { ?s |<urn:p> ?o }",                                        "SELECT (1 AS ?x) (2 AS ?x) {}",
        "SELECT (?x + ?y) {}",                                    "SELECT (?x AS <urn:x>) {}",                                          "SELECT (COUNT(?x, ?y) AS ?count) {}",
        "SELECT (SUM(*) AS ?sum) {}",                             "SELECT (datatype(DISTINCT ?x) AS ?dt) {}",                           "SELECT (COUNT(?x; SEPARATOR=',') AS ?count) {}",
        "SELECT (unknown(?x) AS ?value) {}",                      "SELECT (GROUP_CONCAT(?x; SEPARATOR='x'^^<urn:type>) AS ?joined) {}", "SELECT * { ?s ?p ?o FILTER(?o IN(1,)) }",
        "SELECT * { ?s ?p ?o FILTER(?o < ?s < 3) }",              "SELECT * { ?s ?p ?o FILTER(?o & true) }",                            "SELECT * { ?s ?p ?o BIND(?o AS ?o) }",
        "SELECT * { BIND(1 AS ?x) BIND(2 AS ?x) }",               "SELECT * { FILTER true }",                                           "SELECT * { { ?s ?p ?o } BIND(1 AS ?s) }",
        "SELECT * { { ?s ?p ?o } UNION }",                        "SELECT * { MINUS ?s ?p ?o }",                                        "SELECT * { FILTER(EXISTS ?s ?p ?o) }",
        "CONSTRUCT { ?s ?p ?o }",                                 "SELECT * FROM NAMED WHERE {}",                                       "SELECT * { {} SELECT * {} }",
        "SELECT (1 AS ?x) { SELECT (2 AS ?x) {} }",               "SELECT * { SELECT (1 AS ?x) (2 AS ?x) {} }",                         "SELECT * { SELECT * WHERE }",
        "SELECT * {} VALUES (?x ?x) { (1 2) }",                   "SELECT * { VALUES (?x ?y) { (1) } }",                                "SELECT * { VALUES (?x ?y) { (1 2 3) } }",
        "SELECT (?o AS ?x) { ?s ?p ?o } GROUP BY ?s",             "SELECT (STR(?o) AS ?x) { ?s ?p ?o } GROUP BY ?s",                    "SELECT * { VALUES ?x { _:blank } }",
        "SELECT ?x {} GROUP BY (?a AS ?x) (?b AS ?x)",            "SELECT * {} GROUP BY ?x",                                            "SELECT ?x {} HAVING ?x",
        "SELECT ?x {} ORDER BY ASC ?x",                           "SELECT ?x {} ORDER BY",                                              "SELECT ?x {} LIMIT -1",
        "SELECT ?x {} LIMIT +1",                                  "SELECT ?x {} LIMIT 1 LIMIT 2",                                       "SELECT ?x {} OFFSET 1 OFFSET 2",
        "SELECT ?x {} LIMIT 1.5",                                 "SELECT (?x AS ?g) { ?g ?p ?o } GROUP BY (?x AS ?g)",                 "SELECT ?g {} GROUP BY (?x AS ?g) VALUES ?g { 1 }",
        "SELECT * { GRAPH \"name\" {} }",                         "SELECT * { GRAPH <urn:g> }",                                         "SELECT * { SERVICE SILENT SILENT <urn:s> {} }",
        "SELECT * { SERVICE _:endpoint {} }",                     "SELECT * { SILENT <urn:s> {} }",                                     "SELECT * { GRAPH ?g {} BIND(1 AS ?g) }",
        "SELECT * { SERVICE ?endpoint {} BIND(1 AS ?endpoint) }", "SELECT (BOUND(1) AS ?x) {}",                                         "SELECT (RAND(1) AS ?x) {}",
        "SELECT (BNODE(1, 2) AS ?x) {}",                          "SELECT (LANGMATCHES(?x) AS ?match) {}",                              "SELECT (ABS() AS ?x) {}",
        "SELECT (sameTerm(?x, ?y, ?z) AS ?same) {}",              "SELECT (isIRI(*) AS ?test) {}",                                      "SELECT (STR(DISTINCT ?x) AS ?value) {}",
        "SELECT (SUBSTR(?x) AS ?value) {}",                       "SELECT (SUBSTR(?x, 1, 2, 3) AS ?value) {}",                          "SELECT (REGEX(?x) AS ?match) {}",
        "SELECT (REPLACE(?x, 'a') AS ?value) {}",                 "SELECT (REPLACE(?x, 'a', 'b', 'i', 'x') AS ?value) {}",              "SELECT (STRLANG(?x) AS ?value) {}",
        "SELECT (CONTAINS(?x, 'a', 'b') AS ?value) {}",           "SELECT (CONCAT(DISTINCT ?x) AS ?value) {}",                          "SELECT (NOW(1) AS ?value) {}",
        "SELECT (YEAR() AS ?value) {}",                           "SELECT (YEAR(?x, ?y) AS ?value) {}",                                 "SELECT (IF(?x, ?y) AS ?value) {}",
        "SELECT (IF(?w, ?x, ?y, ?z) AS ?value) {}",               "SELECT (SHA256(?x, ?y) AS ?value) {}",                               "SELECT (COALESCE(DISTINCT ?x) AS ?value) {}",
        "SELECT (COALESCE(*) AS ?value) {}",
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
            "SELECT DISTINCT ?s (?s + COUNT(ex:function(?o, 2)) AS ?value) " ++
            "(BOUND(?s) AS ?present) (ABS(-2) AS ?magnitude) " ++
            "(REPLACE(STR(?s), 'a', 'b', 'i') AS ?replaced) " ++
            "(IF(BOUND(?s), SHA256(STR(?s)), '') AS ?digest) WHERE { " ++
            "[ ex:inner \"hello\\n\"@EN ] (^ex:p/ex:item+|!(ex:skip|^a))? (12.5 true) ; " ++
            "ex:q ?o, \"value\"^^ex:kind . " ++
            "FILTER(?o NOT IN(1, 2)) BIND(?o+1 AS ?bound) " ++
            "FILTER(EXISTS { ?o ex:seen true } && NOT EXISTS { ?o ex:hidden true }) " ++
            "MINUS { ?o ex:removed true } " ++
            "{ SELECT (?o AS ?nested) { ?o ex:nested true } } " ++
            "GRAPH ?graph { ?o ex:graph true } " ++
            "SERVICE SILENT ex:service { ?o ex:remote true } } " ++
            "GROUP BY ?s HAVING (COUNT(*) > 0) " ++
            "ORDER BY DESC(COUNT(*)) ?s LIMIT 5 OFFSET 1 " ++
            "VALUES (?extra ?missing) { (1 UNDEF) }",
    });
}

fn expectQueryParses(allocator: std.mem.Allocator, input: []const u8) !void {
    var query = try parseQuery(allocator, input);
    defer query.deinit();
    try std.testing.expectEqual(@as(usize, 14), query.patterns().len);
}

const runner = @import("sparql_query_syntax_conformance_runner.zig");

const expected_failures = [_][]const u8{};

test "W3C SPARQL 1.1 query syntax manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/sparql11-query-syntax/",
        .expected_count = 97,
        .expected_positive_count = 65,
        .expected_negative_count = 32,
        .expected_failures = &expected_failures,
    });
}

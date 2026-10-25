const runner = @import("sparql_query_syntax_conformance_runner.zig");

const expected_failures = [_][]const u8{
    "test_21",    "test_22",    "test_23",                       "test_24",                       "test_25",  "test_26",  "test_27",
    "test_28",    "test_29",    "test_30",                       "test_35a",                      "test_36a", "test_38a", "test_41",
    "test_42",    "test_56",    "test_57",                       "test_58",                       "test_59",  "test_64",  "test_66",
    "test_pn_01", "test_pn_02", "test_group_by_values_scope_01", "test_group_by_values_scope_02",
};

test "W3C SPARQL 1.1 query syntax manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/sparql11-query-syntax/",
        .expected_count = 97,
        .expected_positive_count = 65,
        .expected_negative_count = 32,
        .expected_failures = &expected_failures,
    });
}

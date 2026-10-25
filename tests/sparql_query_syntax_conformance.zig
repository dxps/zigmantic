const runner = @import("sparql_query_syntax_conformance_runner.zig");

const expected_failures = [_][]const u8{
    "test_1",                        "test_2",                        "test_3",     "test_4",       "test_5",                   "test_6",                       "test_7",
    "test_8",                        "test_9",                        "test_10",    "test_11",      "test_12",                  "test_13",                      "test_14",
    "test_15",                       "test_16",                       "test_17",    "test_18",      "test_19",                  "test_20",                      "test_21",
    "test_22",                       "test_23",                       "test_24",    "test_25",      "test_26",                  "test_27",                      "test_28",
    "test_29",                       "test_30",                       "test_31",    "test_32",      "test_33",                  "test_34",                      "test_35a",
    "test_36a",                      "test_38a",                      "test_40",    "test_41",      "test_42",                  "test_53",                      "test_54",
    "test_55",                       "test_56",                       "test_57",    "test_58",      "test_59",                  "test_63",                      "test_64",
    "test_66",                       "test_pn_01",                    "test_pn_02", "test_pn_03",   "test_pn_04",               "test_pn_05",                   "test_pn_06",
    "test_pn_07",                    "test_pn_08",                    "test_pn_09", "test_pp_coll", "test_codepoint_escape_01", "test_codepoint_boundaries_04", "test_codepoint_boundaries_escaped_05",
    "test_group_by_values_scope_01", "test_group_by_values_scope_02",
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

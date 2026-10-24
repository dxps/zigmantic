const runner = @import("trig_conformance_runner.zig");

test "W3C RDF 1.1 TriG manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-trig/",
        .expected_count = 357,
        .expected_failures = &[_][]const u8{
            "anonymous_blank_node_graph",
            "trig-syntax-bad-base-04",
            "trig-syntax-bad-base-05",
            "trig-syntax-bad-prefix-06",
            "trig-syntax-bad-prefix-07",
            "trig-syntax-struct-06",
            "trig-syntax-struct-07",
            "trig-syntax-minimal-whitespace-01",
            "prefix_with_PN_CHARS_BASE_character_boundaries",
            "sole_blankNodePropertyList",
            "blankNodePropertyList_as_object_containing_objectList",
            "blankNodePropertyList_as_object_containing_objectList_of_two_objects",
            "trig-kw-graph-01",
            "trig-kw-graph-04",
            "trig-kw-graph-05",
            "trig-kw-graph-06",
            "trig-kw-graph-07",
            "trig-kw-graph-08",
            "trig-kw-graph-09",
        },
    });
}

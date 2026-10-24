const runner = @import("turtle_conformance_runner.zig");

test "W3C RDF 1.1 Turtle manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-turtle/",
        .expected_count = 313,
        .expected_failures = &[_][]const u8{
            "prefix_with_PN_CHARS_BASE_character_boundaries",
            "prefix_with_non_leading_extras",
            "reserved_escaped_localName",
            "sole_blankNodePropertyList",
            "nested_blankNodePropertyLists",
            "blankNodePropertyList_containing_collection",
            "number_sign_following_localName",
            "number_sign_following_PNAME_NS",
            "turtle-syntax-pname-esc-01",
            "turtle-syntax-pname-esc-02",
            "turtle-syntax-bnode-08",
            "turtle-syntax-bnode-09",
            "turtle-syntax-bnode-10",
            "turtle-syntax-bad-lang-01",
            "turtle-syntax-bad-pname-01",
            "turtle-syntax-bad-pname-02",
            "turtle-syntax-bad-ln-escape-start",
            "turtle-syntax-bad-ln-escape",
        },
    });
}

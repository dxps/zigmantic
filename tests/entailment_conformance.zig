const runner = @import("entailment_conformance_runner.zig");

test "W3C RDF 1.1 model-theory entailment manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-mt/",
        .expected_count = 48,
        .expected_failures = &[_][]const u8{
            "datatypes-non-well-formed-literal-2",
            "datatypes-semantic-equivalence-within-type-1",
            "datatypes-semantic-equivalence-within-type-2",
            "datatypes-semantic-equivalence-between-datatypes",
            "datatypes-range-clash",
            "datatypes-test010",
            "rdfs-entailment-test001",
            "xmlsch-02-whitespace-facet-2",
            "xmlsch-02-whitespace-facet-4",
            "literal-type",
            "float-round-same",
            "float-infinity",
            "double-round-same",
            "double-infinity",
        },
    });
}

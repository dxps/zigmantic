const runner = @import("entailment_conformance_runner.zig");

test "W3C RDF 1.1 model-theory entailment manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-mt/",
        .expected_count = 51,
        .expected_failures = &[_][]const u8{
            "datatypes-intensional-xsd-integer-string-incompatible",
            "datatypes-non-well-formed-literal-2",
            "datatypes-semantic-equivalence-within-type-1",
            "datatypes-semantic-equivalence-within-type-2",
            "datatypes-semantic-equivalence-between-datatypes",
            "datatypes-range-clash",
            "datatypes-test010",
            "pfps-10-non-well-formed-literal-1",
            "rdfs-entailment-test001",
            "rdfs-entailment-test002",
            "rdfs-subPropertyOf-semantics-test001",
            "xmlsch-02-whitespace-facet-2",
            "xmlsch-02-whitespace-facet-3",
            "xmlsch-02-whitespace-facet-4",
            "literal-type",
            "float-round-same",
            "float-infinity",
            "double-round-same",
            "double-infinity",
        },
    });
}

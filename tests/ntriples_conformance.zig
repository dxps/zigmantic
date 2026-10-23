const runner = @import("conformance_runner.zig");
const zigmantic = @import("zigmantic");

test "W3C RDF 1.1 N-Triples syntax manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-ntriples/",
        .positive_type = "rdf:type rdft:TestNTriplesPositiveSyntax",
        .negative_type = "rdf:type rdft:TestNTriplesNegativeSyntax",
        .expected_count = 70,
        .parse = zigmantic.rdf_io.parseNTriples,
    });
}

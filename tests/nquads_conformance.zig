const runner = @import("conformance_runner.zig");
const zigmantic = @import("zigmantic");

test "W3C RDF 1.1 N-Quads syntax manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-nquads/",
        .positive_type = "a rdft:TestNQuadsPositiveSyntax",
        .negative_type = "a rdft:TestNQuadsNegativeSyntax",
        .expected_count = 87,
        .parse = zigmantic.rdf_io.parseNQuads,
    });
}

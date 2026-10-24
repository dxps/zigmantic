const runner = @import("entailment_conformance_runner.zig");

test "W3C RDF 1.1 model-theory entailment manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-mt/",
        .expected_count = 48,
        .expected_failures = &[_][]const u8{},
    });
}

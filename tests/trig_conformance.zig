const runner = @import("trig_conformance_runner.zig");

test "W3C RDF 1.1 TriG manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-trig/",
        .expected_count = 357,
        .expected_failures = &[_][]const u8{
            "trig-syntax-bad-base-04",
            "trig-syntax-bad-base-05",
            "trig-syntax-bad-prefix-06",
            "trig-syntax-bad-prefix-07",
            "trig-syntax-minimal-whitespace-01",
        },
    });
}

const runner = @import("turtle_conformance_runner.zig");

test "W3C RDF 1.1 Turtle manifest" {
    try runner.run(.{
        .suite_dir = "tests/conformance/rdf11-turtle/",
        .expected_count = 313,
        .expected_failures = &[_][]const u8{},
    });
}

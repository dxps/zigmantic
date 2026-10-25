const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const zigmantic = b.addModule("zigmantic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const library_tests = b.addTest(.{
        .root_module = zigmantic,
    });
    const run_library_tests = b.addRunArtifact(library_tests);

    const ntriples_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/ntriples_conformance.zig"),
        .target = target,
    });
    ntriples_conformance_module.addImport("zigmantic", zigmantic);
    const ntriples_conformance_tests = b.addTest(.{
        .root_module = ntriples_conformance_module,
    });
    const run_ntriples_conformance_tests = b.addRunArtifact(ntriples_conformance_tests);

    const nquads_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/nquads_conformance.zig"),
        .target = target,
    });
    nquads_conformance_module.addImport("zigmantic", zigmantic);
    const nquads_conformance_tests = b.addTest(.{
        .root_module = nquads_conformance_module,
    });
    const run_nquads_conformance_tests = b.addRunArtifact(nquads_conformance_tests);

    const turtle_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/turtle_conformance.zig"),
        .target = target,
    });
    turtle_conformance_module.addImport("zigmantic", zigmantic);
    const turtle_conformance_tests = b.addTest(.{
        .root_module = turtle_conformance_module,
    });
    const run_turtle_conformance_tests = b.addRunArtifact(turtle_conformance_tests);

    const trig_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/trig_conformance.zig"),
        .target = target,
    });
    trig_conformance_module.addImport("zigmantic", zigmantic);
    const trig_conformance_tests = b.addTest(.{
        .root_module = trig_conformance_module,
    });
    const run_trig_conformance_tests = b.addRunArtifact(trig_conformance_tests);

    const entailment_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/entailment_conformance.zig"),
        .target = target,
    });
    entailment_conformance_module.addImport("zigmantic", zigmantic);
    const entailment_conformance_tests = b.addTest(.{
        .root_module = entailment_conformance_module,
    });
    const run_entailment_conformance_tests = b.addRunArtifact(entailment_conformance_tests);

    const sparql_query_syntax_conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/sparql_query_syntax_conformance.zig"),
        .target = target,
    });
    sparql_query_syntax_conformance_module.addImport("zigmantic", zigmantic);
    const sparql_query_syntax_conformance_tests = b.addTest(.{
        .root_module = sparql_query_syntax_conformance_module,
    });
    const run_sparql_query_syntax_conformance_tests = b.addRunArtifact(
        sparql_query_syntax_conformance_tests,
    );

    const test_step = b.step("test", "Run all Zigmantic tests");
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_ntriples_conformance_tests.step);
    test_step.dependOn(&run_nquads_conformance_tests.step);
    test_step.dependOn(&run_turtle_conformance_tests.step);
    test_step.dependOn(&run_trig_conformance_tests.step);
    test_step.dependOn(&run_entailment_conformance_tests.step);
    test_step.dependOn(&run_sparql_query_syntax_conformance_tests.step);
}

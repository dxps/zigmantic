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

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/ntriples_conformance.zig"),
        .target = target,
    });
    conformance_module.addImport("zigmantic", zigmantic);
    const conformance_tests = b.addTest(.{
        .root_module = conformance_module,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);

    const test_step = b.step("test", "Run all Zigmantic tests");
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_conformance_tests.step);
}

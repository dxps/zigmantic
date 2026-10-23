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

    const test_step = b.step("test", "Run all Zigmantic tests");
    test_step.dependOn(&run_library_tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const common = b.dependency("zighh", .{}).module("common");

    const deps = [_]std.Build.ModuleDependency{
        .{ .name = "common", .module = common },
    };

    _ = b.addModule("blox", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &deps,
    });

    // tests
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
    });

    for (deps) |dep| tests.addModule(dep.name, dep.module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run blox tests");
    test_step.dependOn(&run_tests.step);

    // autodoc
    const docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });

    const install_docs = b.step("docs", "build and install autodocs");
    install_docs.dependOn(&docs.step);
}

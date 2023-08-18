const std = @import("std");

pub fn build(b: *std.Build) void {
    const common = b.dependency("zighh", .{}).module("common");

    _ = b.addModule("blox", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "common", .module = common },
        },
    });

    // tests
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
    });
    tests.addModule("common", common);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run blox tests");

    test_step.dependOn(&run_tests.step);
}

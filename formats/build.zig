const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const interfaces = b.dependency("interfaces", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("formats", .{
        .root_source_file = b.path("formats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = interfaces.module("interfaces") }},
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run format parser tests");
    test_step.dependOn(&run_tests.step);
}

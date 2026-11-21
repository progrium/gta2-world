const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const formats_dep = b.dependency("formats", .{ .target = target, .optimize = optimize });

    // Native tool: inspect real files, write synthetic fixtures.
    const exe = b.addExecutable(.{
        .name = "s1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "formats", .module = formats_dep.module("formats") }},
        }),
    });
    b.installArtifact(exe);

    // WASM module for the viewer.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const formats_wasm = b.dependency("formats", .{ .target = wasm_target, .optimize = optimize });
    const wasm = b.addExecutable(.{
        .name = "s1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "formats", .module = formats_wasm.module("formats") }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const web = b.step("web", "Build the viewer into zig-out/web");
    web.dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "s1.wasm").step);
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("web"), .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
    const gen = b.addRunArtifact(exe);
    gen.addArg("fixtures");
    const fixtures = gen.addOutputDirectoryArg("fixtures");
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = fixtures, .install_dir = .{ .custom = "web" }, .install_subdir = "fixtures" }).step);
    b.getInstallStep().dependOn(web);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the s1 tool (inspect / fixtures)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = formats_dep.module("formats") })).step);
}

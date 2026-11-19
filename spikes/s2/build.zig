//! Spike S2 build. Run from spikes/s2:
//!   zig build -Doptimize=ReleaseFast        native `s2` + `s2.wasm` into zig-out/
//!   zig build test                          sim unit tests
//!   zig build web -Doptimize=ReleaseFast    also copies s2.wasm into web/

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sim_native = b.createModule(.{ .root_source_file = b.path("../../sim/sim.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "s2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sim", .module = sim_native }},
        }),
    });
    b.installArtifact(exe);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sim_wasm = b.createModule(.{ .root_source_file = b.path("../../sim/sim.zig"), .target = wasm_target, .optimize = optimize });
    const wasm = b.addExecutable(.{
        .name = "s2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sim", .module = sim_wasm }},
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 1 << 20;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.getInstallStep().dependOn(&install_wasm.step);

    const web = b.step("web", "Copy s2.wasm into web/");
    const wf = b.addUpdateSourceFiles();
    wf.addCopyFileToSource(wasm.getEmittedBin(), "web/s2.wasm");
    web.dependOn(&wf.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("../../sim/tests.zig"), .target = target, .optimize = optimize }) });
    const test_step = b.step("test", "Run sim tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

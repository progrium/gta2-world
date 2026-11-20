//! client/wasm: the browser's Zig module. Links sim/ (dm16), formats/ and the
//! renderer's Zig side into one game.wasm that the shell loads.
//!
//!   zig build              zig-out/web/game.wasm (ReleaseSmall by default)
//!   zig build test         native tests of the exported game loop

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{ .name = "game", .root_module = gameModule(b, wasm_target, optimize) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "game.wasm").step);

    const tests = b.addTest(.{ .root_module = gameModule(b, target, optimize) });
    b.step("test", "Run client/wasm tests").dependOn(&b.addRunArtifact(tests).step);
}

fn gameModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const args = .{ .target = target, .optimize = optimize };
    const interfaces = b.dependency("interfaces", args).module("interfaces");
    // net/ has no package of its own for hosts; build its module here so it
    // shares this build's interfaces module (one abi.Grid type).
    const net = b.createModule(.{
        .root_source_file = b.path("../../net/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = interfaces }},
    });
    return b.createModule(.{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = interfaces },
            .{ .name = "net", .module = net },
            .{ .name = "formats", .module = b.dependency("formats", args).module("formats") },
            .{ .name = "sim", .module = b.dependency("sim", args).module("sim") },
            .{ .name = "render", .module = b.dependency("render", args).module("render") },
        },
    });
}

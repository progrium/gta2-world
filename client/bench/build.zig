//! client/bench: the S5 handling bench (site/s5). One car from sim/ on the
//! synthetic test map, with the player's .gci and style car info through
//! formats/, in its own small s5.wasm.
//!
//!   zig build -Doptimize=ReleaseSmall   zig-out/web/s5.wasm
//!   zig build test         native tests, including the self-test hash

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{ .name = "s5", .root_module = benchModule(b, wasm_target, optimize) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "s5.wasm").step);

    const tests = b.addTest(.{ .root_module = benchModule(b, target, optimize) });
    b.step("test", "Run bench tests").dependOn(&b.addRunArtifact(tests).step);
}

fn benchModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const args = .{ .target = target, .optimize = optimize };
    return b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = b.dependency("interfaces", args).module("interfaces") },
            .{ .name = "formats", .module = b.dependency("formats", args).module("formats") },
            .{ .name = "sim", .module = b.dependency("sim", args).module("sim") },
        },
    });
}

//! Golden replay runner and benches for sim/. Run from tools/replay:
//!   zig build -Doptimize=ReleaseFast        native `replay` + `replay.wasm` into zig-out/bin
//!   zig build golden                        re-record golden/ (after an intended sim change)
//!   node verify-wasm.mjs zig-out/bin/replay.wasm golden [hash200]

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sim_native = b.dependency("sim", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sim", .module = sim_native.module("sim") }},
        }),
    });
    b.installArtifact(exe);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sim_wasm = b.dependency("sim", .{ .target = wasm_target, .optimize = optimize });
    const wasm = b.addExecutable(.{
        .name = "replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sim", .module = sim_wasm.module("sim") }},
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 1 << 20;
    b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{}).step);

    const rec = b.addRunArtifact(exe);
    rec.addArg("record");
    rec.addDirectoryArg(b.path("golden"));
    b.step("golden", "Re-record golden/inputs.bin and golden/hashes.bin").dependOn(&rec.step);
}

//! Golden replay runner and benches for sim/. Run from tools/replay:
//!   zig build -Doptimize=ReleaseFast        native `replay` + `replay.wasm` into zig-out/bin
//!   zig build golden                        re-record golden/ with stats.txt and REPORT.md (QA only)
//!   node verify-wasm.mjs zig-out/bin/replay.wasm golden [hash200]

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sim_native = b.dependency("sim", .{ .target = target, .optimize = optimize });
    const formats_native = b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats");
    // The single-player golden's player is the level runner's autopilot.
    const autopilot = b.createModule(.{ .root_source_file = b.path("../level/src/autopilot.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sim", .module = sim_native.module("sim") }} });
    const exe = b.addExecutable(.{
        .name = "replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sim", .module = sim_native.module("sim") },
                .{ .name = "formats", .module = formats_native },
                .{ .name = "autopilot", .module = autopilot },
            },
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
            .imports = &.{
                .{ .name = "sim", .module = sim_wasm.module("sim") },
                .{ .name = "formats", .module = b.dependency("formats", .{ .target = wasm_target, .optimize = optimize }).module("formats") },
            },
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 1 << 20;
    b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // Re-recording also rewrites golden/stats.txt and golden/REPORT.md (what
    // changed in play terms). Only the QA merge train re-records.
    const rec = b.addRunArtifact(exe);
    rec.addArg("rerecord");
    rec.addDirectoryArg(b.path("golden"));
    b.step("golden", "Re-record golden/ with a play-terms report").dependOn(&rec.step);

    const sp_rec = b.addRunArtifact(exe);
    sp_rec.addArg("sp-record");
    sp_rec.addDirectoryArg(b.path("golden-sp"));
    b.step("golden-sp", "Re-record golden-sp/ (single player)").dependOn(&sp_rec.step);
}

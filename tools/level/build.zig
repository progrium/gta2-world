//! Headless level runner (docs/plan-notes.md, workstream Q). Native only;
//! reads the player's own data from --data and is never run in CI.
//!   zig build -Doptimize=ReleaseFast
//!   zig-out/bin/level --data ~/gta2/data --map wil.gmp [--ticks N] [--seed S]
//!   zig-out/bin/level --data ~/gta2/data --all --out results/latest.md

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sim = b.dependency("sim", .{ .target = target, .optimize = optimize }).module("sim");
    const formats = b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats");
    // The invariant checker, play statistics and bots are shared with the
    // replay tool.
    const qa = b.createModule(.{ .root_source_file = b.path("../replay/src/qa.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sim", .module = sim }} });
    const bots = b.createModule(.{ .root_source_file = b.path("../replay/src/bots.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sim", .module = sim }} });
    const exe = b.addExecutable(.{
        .name = "level",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sim", .module = sim },
                .{ .name = "formats", .module = formats },
                .{ .name = "qa", .module = qa },
                .{ .name = "bots", .module = bots },
            },
        }),
    });
    b.installArtifact(exe);
}

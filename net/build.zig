//! Workstream C: netcode. Run from net/:
//!   zig build test                          unit tests (native)
//!   zig build -Doptimize=ReleaseFast && zig-out/bin/soak [options]
//!   zig build wasm                          check the client side builds for wasm32

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const itf = b.createModule(.{ .root_source_file = b.path("../interfaces/zig/src/root.zig"), .target = target, .optimize = optimize });
    const net = b.addModule("net", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = itf }},
    });

    const tests = b.addTest(.{ .root_module = net });
    b.step("test", "Run netcode tests").dependOn(&b.addRunArtifact(tests).step);

    // The soak's world: the stand-in arena (default) or sim/ (-Dsim=real).
    const sim_choice = b.option([]const u8, "sim", "soak world: test (net/ arena sim, default) or real (sim/ dm16)") orelse "test";
    const world = if (std.mem.eql(u8, sim_choice, "real")) blk: {
        const sim = b.createModule(.{ .root_source_file = b.path("../sim/sim.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "interfaces", .module = itf }} });
        const formats = b.createModule(.{ .root_source_file = b.path("../formats/formats.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "interfaces", .module = itf }} });
        break :blk b.createModule(.{ .root_source_file = b.path("tools/soak_realsim.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "interfaces", .module = itf },
            .{ .name = "sim", .module = sim },
            .{ .name = "formats", .module = formats },
        } });
    } else b.createModule(.{ .root_source_file = b.path("tools/soak_testsim.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "interfaces", .module = itf },
        .{ .name = "net", .module = net },
    } });
    const soak = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "interfaces", .module = itf },
                .{ .name = "net", .module = net },
                .{ .name = "soak_world", .module = world },
            },
        }),
    });
    b.installArtifact(soak);
    const run_soak = b.addRunArtifact(soak);
    b.step("soak", "Run the headless network soak").dependOn(&run_soak.step);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const itf_wasm = b.createModule(.{ .root_source_file = b.path("../interfaces/zig/src/root.zig"), .target = wasm_target, .optimize = .ReleaseSmall });
    const wasm = b.addLibrary(.{
        .name = "net",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "interfaces", .module = itf_wasm }},
        }),
    });
    b.step("wasm", "Check the netcode builds for wasm32").dependOn(&wasm.step);
}

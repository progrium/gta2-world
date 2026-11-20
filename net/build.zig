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

    const soak = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "interfaces", .module = itf },
                .{ .name = "net", .module = net },
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

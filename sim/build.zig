//! sim/ as a Zig package. Hosts depend on it by path and import module "sim":
//!
//!   .dependencies = .{ .sim = .{ .path = "../sim" } },
//!   const sim = b.dependency("sim", .{ .target = target, .optimize = optimize });
//!   exe.root_module.addImport("sim", sim.module("sim"));
//!
//!   zig build test    unit tests (native)
//!   zig build wasm    check that the sim builds for wasm32-freestanding

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ifaces = b.dependency("interfaces", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("sim", .{
        .root_source_file = b.path("sim.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = ifaces.module("interfaces") }},
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = ifaces.module("interfaces") },
            // Tests only: the script tests assemble their scripts with scrasm.
            .{ .name = "formats", .module = b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats") },
        },
    }) });
    _ = mod;
    b.step("test", "Run sim tests").dependOn(&b.addRunArtifact(tests).step);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const ifaces_wasm = b.dependency("interfaces", .{ .target = wasm_target, .optimize = optimize });
    const wasm = b.addLibrary(.{
        .name = "sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sim.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "interfaces", .module = ifaces_wasm.module("interfaces") }},
        }),
    });
    b.step("wasm", "Check the sim builds for wasm32").dependOn(&wasm.step);
}

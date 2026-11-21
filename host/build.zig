//! host/: the browser host. server/src's Manager + Session + snapshot policy
//! + replay recorder, hosting the same comptime Sim the native server does,
//! built for wasm32-freestanding so a player's tab can run a game for others.
//!
//!   zig build                 zig-out/web/host.wasm (ReleaseFast by default)
//!                             and host-police.wasm (deathmatch with police)
//!   zig build -Dsim=stub      against the I1 conformance stub instead of sim/
//!
//! Only the wasm target: server/src/util.zig needs libc (module "c") on any
//! other target. host/soak tests the built module in Node and Chromium.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default fast)") orelse .fast;
    const sim_choice = b.option([]const u8, "sim", "real (../sim, default) or stub (abi.Stub)") orelse "real";

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    addHost(b, wasm_target, optimize, sim_choice, "host");
    // A room with police on runs the dmp16 sim (the host's room setting).
    if (!std.mem.eql(u8, sim_choice, "stub")) addHost(b, wasm_target, optimize, "police", "host-police");
}

fn addHost(b: *std.Build, wasm_target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, sim_choice: []const u8, name: []const u8) void {
    const wasm = b.addExecutable(.{ .name = name, .root_module = hostModule(b, wasm_target, optimize, sim_choice) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // The sim's state and a 1 MiB grid live in linear memory; let it grow.
    wasm.initial_memory = 32 << 20;
    wasm.max_memory = 1 << 30;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, b.fmt("{s}.wasm", .{name})).step);
}

fn serverModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const args = .{ .target = target, .optimize = optimize };
    return b.createModule(.{
        .root_source_file = b.path("../server/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = b.dependency("interfaces", args).module("interfaces") },
            .{ .name = "formats", .module = b.dependency("formats", args).module("formats") },
        },
    });
}

fn hostModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, sim_choice: []const u8) *std.Build.Module {
    const args = .{ .target = target, .optimize = optimize };
    const interfaces = b.dependency("interfaces", args).module("interfaces");
    // The same switch as server/build.zig: sim/ (dm16) or the I1 stub.
    const sim_impl = if (std.mem.eql(u8, sim_choice, "stub")) b.createModule(.{
        .root_source_file = b.path("../server/src/sim_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = interfaces }},
    }) else b.createModule(.{
        .root_source_file = b.path(if (std.mem.eql(u8, sim_choice, "police")) "../server/src/sim_police.zig" else "../server/src/sim_real.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = interfaces },
            .{ .name = "sim", .module = b.dependency("sim", args).module("sim") },
        },
    });
    return b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "interfaces", .module = interfaces },
            .{ .name = "server", .module = serverModule(b, target, optimize) },
            .{ .name = "sim_impl", .module = sim_impl },
            // Car models: the same loader the offline game uses (client/wasm loadCarInfo).
            .{ .name = "formats", .module = b.dependency("formats", args).module("formats") },
            .{ .name = "sim", .module = b.dependency("sim", args).module("sim") },
        },
    });
}

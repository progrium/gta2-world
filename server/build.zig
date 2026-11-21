const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = b.option([]const u8, "deps", "prefix where ngtcp2/nghttp3 are installed") orelse "deps/out";
    const sim_choice = b.option([]const u8, "sim", "real (../sim dm16, default), police (../sim dmp16: deathmatch with police) or stub (abi.Stub)") orelse "real";

    const interfaces = b.dependency("interfaces", .{ .target = target, .optimize = optimize }).module("interfaces");
    const formats = b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats");

    // The sim this binary hosts: workstream A's `sim/` (dm16) by default,
    // or the I1 conformance stub with -Dsim=stub.
    const sim_impl = if (std.mem.eql(u8, sim_choice, "stub")) b.createModule(.{
        .root_source_file = b.path("src/sim_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "interfaces", .module = interfaces }},
    }) else b.createModule(.{
        .root_source_file = b.path(if (std.mem.eql(u8, sim_choice, "police")) "src/sim_police.zig" else "src/sim_real.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interfaces", .module = interfaces },
            .{ .name = "sim", .module = b.dependency("sim", .{ .target = target, .optimize = optimize }).module("sim") },
        },
    });

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{deps}) });

    const exe = b.addExecutable(.{
        .name = "gta2-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = tc.createModule() },
                .{ .name = "interfaces", .module = interfaces },
                .{ .name = "formats", .module = formats },
                .{ .name = "sim_impl", .module = sim_impl },
            },
        }),
    });
    const m = exe.root_module;
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libngtcp2_crypto_gnutls.a", .{deps}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libngtcp2.a", .{deps}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{deps}) });
    m.linkSystemLibrary("gnutls", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the server").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

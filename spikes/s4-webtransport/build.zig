const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = b.option([]const u8, "deps", "prefix where ngtcp2/nghttp3 are installed") orelse "deps/out";

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{deps}) });

    const exe = b.addExecutable(.{
        .name = "s4-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "c", .module = tc.createModule() }},
        }),
    });
    const m = exe.root_module;
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libngtcp2_crypto_gnutls.a", .{deps}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libngtcp2.a", .{deps}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{deps}) });
    m.linkSystemLibrary("gnutls", .{});
    m.addAnonymousImport("index.html", .{ .root_source_file = b.path("web/index.html") });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the echo server").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raw_version = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(128),
    ) catch @panic("failed to read VERSION");
    const version = std.mem.trim(u8, raw_version, " \t\r\n");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const plandalf_build_options = b.addOptions();
    plandalf_build_options.addOption([]const u8, "version", version);
    plandalf_build_options.addOption(bool, "local_api_server", true);

    const bongo_dependency = b.dependency("bongo", .{
        .target = target,
        .optimize = optimize,
    });
    const thrawn_dependency = b.dependency("thrawn", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_dependency = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("plandalf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("sqlite3", .{});
    mod.addImport("bongo", bongo_dependency.module("bongo"));
    mod.addImport("thrawn", thrawn_dependency.module("thrawn"));
    mod.addImport("httpz", httpz_dependency.module("httpz"));
    mod.addOptions("build_options", build_options);
    mod.addOptions("deez_build_options", plandalf_build_options);

    const exe = b.addExecutable(.{
        .name = "plandalf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plandalf", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run Plandalf");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "plandalf-benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plandalf", .module = mod },
            },
        }),
    });
    b.installArtifact(benchmark_exe);
    const benchmark_run = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step(
        "benchmark",
        "Run deterministic Plandalf benchmarks",
    );
    benchmark_step.dependOn(&benchmark_run.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // The Plandalf application is SQLite-only. Legacy Mongo implementation
    // modules remain temporarily in-tree while the public product surface is
    // simplified, but there is no Mongo integration-test build target.
}

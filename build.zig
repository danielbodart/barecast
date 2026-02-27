const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);

    // --- barecast (main binary, unprivileged) ---
    const exe = b.addExecutable(.{
        .name = "barecast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.linkLibC();

    b.installArtifact(exe);

    // --- barecast-kms (privileged helper, CAP_SYS_ADMIN) ---
    const kms_exe = b.addExecutable(.{
        .name = "barecast-kms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kms.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Will link libdrm when real DRM code is added:
    // kms_exe.linkSystemLibrary("drm");
    kms_exe.linkLibC();

    b.installArtifact(kms_exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run barecast");
    run_step.dependOn(&run_cmd.step);

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");

    // Main module tests
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // KMS protocol tests (pure Zig, no libdrm needed for protocol logic)
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    // Property tests (minish)
    const minish_dep = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    });

    const prop_exe = b.addExecutable(.{
        .name = "prop-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prop_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minish", .module = minish_dep.module("minish") },
                .{ .name = "protocol", .module = b.createModule(.{
                    .root_source_file = b.path("src/protocol.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });

    const run_prop = b.addRunArtifact(prop_exe);
    const prop_step = b.step("prop-test", "Run property-based tests");
    prop_step.dependOn(&run_prop.step);
    test_step.dependOn(&run_prop.step);

    // --- Static analysis (zwanzig) ---
    const analyze_step = b.step("analyze", "Run zwanzig static analyzer on src/");
    const zwanzig_dep = b.dependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    });
    const zwanzig_exe = zwanzig_dep.artifact("zwanzig");
    const zwanzig_run = b.addRunArtifact(zwanzig_exe);
    zwanzig_run.addArgs(&.{ "--do", "store-violations-engine" });
    zwanzig_run.addArgs(&.{ "--do", "stack-escape-engine" });
    zwanzig_run.addArgs(&.{ "--do", "unreachable-code-engine" });
    zwanzig_run.addDirectoryArg(b.path("src"));
    analyze_step.dependOn(&zwanzig_run.step);
}

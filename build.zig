const std = @import("std");
const builtin = @import("builtin");
const shared_defs = @import("build_shared.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("build_linux.zig"),
    .macos => @import("build_macos.zig"),
    else => @compileError("Unsupported platform: only Linux and macOS are supported"),
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Build options ────────────────────────────────────────────────────
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);
    const build_options_mod = options.createModule();

    // ── Shared modules (platform-independent) ────────────────────────────
    const input_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/input_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const osc_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/osc_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const viewer_state_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/viewer_state.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codec_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/codec.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ivf_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/ivf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const session_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "input_protocol", .module = input_protocol_mod },
            .{ .name = "viewer_state", .module = viewer_state_mod },
            .{ .name = "codec", .module = codec_mod },
        },
    });
    session_mod.addIncludePath(b.path("libdatachannel/include"));

    const session_recorder_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/session_recorder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ivf", .module = ivf_mod },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "codec", .module = codec_mod },
        },
    });

    const encoder_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/encoder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ivf", .module = ivf_mod },
            .{ .name = "session", .module = session_mod },
            .{ .name = "session_recorder", .module = session_recorder_mod },
            .{ .name = "codec", .module = codec_mod },
        },
    });

    const control_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const terminal_share_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/terminal_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "session", .module = session_mod },
            .{ .name = "osc_parser", .module = osc_parser_mod },
        },
    });

    const shared = shared_defs.SharedModules{
        .build_options = build_options_mod,
        .input_protocol = input_protocol_mod,
        .osc_parser = osc_parser_mod,
        .viewer_state = viewer_state_mod,
        .ivf = ivf_mod,
        .session = session_mod,
        .session_recorder = session_recorder_mod,
        .encoder = encoder_mod,
        .codec = codec_mod,
        .terminal_share = terminal_share_mod,
        .control = control_mod,
    };

    // ── Platform-specific modules ────────────────────────────────────────
    const platform_mods = platform.buildPlatform(b, target, optimize, shared);

    // ── Daemon module (socket listener, session manager) ─────────────────
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "control", .module = control_mod },
            .{ .name = "app_share", .module = platform_mods.app_share },
            .{ .name = "terminal_share", .module = terminal_share_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    if (platform_mods.gpu_detect) |gd_mod| {
        daemon_mod.addImport("gpu_detect", gd_mod);
    }

    // ── CLI module (subcommand parser, socket client) ────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "control", .module = control_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // ── zerocast (main binary, unprivileged) ─────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zerocast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "daemon", .module = daemon_mod },
                .{ .name = "cli", .module = cli_mod },
            },
        }),
    });
    exe.linkLibC();
    shared_defs.linkDatachannel(b, exe);
    b.installArtifact(exe);

    // ── Platform-specific extra binaries ──────────────────────────────────
    platform.buildExtraArtifacts(b, target, optimize, shared);

    // ── Run step ─────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zerocast");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");

    // Pure shared tests (no libdatachannel dependency)
    inline for (.{
        .{ "src/shared/control.zig", true, &[_]std.Build.Module.Import{} },
        .{ "src/shared/osc_parser.zig", false, &[_]std.Build.Module.Import{} },
        .{ "src/shared/ivf.zig", false, &[_]std.Build.Module.Import{} },
        .{ "src/shared/input_protocol.zig", false, &[_]std.Build.Module.Import{} },
        .{ "src/shared/viewer_state.zig", false, &[_]std.Build.Module.Import{} },
    }) |entry| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[0]),
                .target = target,
                .optimize = optimize,
                .link_libc = entry[1],
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Platform-specific pure tests
    if (builtin.os.tag == .macos) {
        const keymap_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/macos/keymap.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(keymap_test).step);
    }

    if (builtin.os.tag == .linux) {
        const keymap_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/linux/keymap.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(keymap_test).step);
    }

    // GPU detect tests (Linux only)
    if (builtin.os.tag == .linux) {
        if (platform_mods.gpu_detect) |gd_mod| {
            const gpu_detect_tests = b.addTest(.{
                .root_module = gd_mod,
            });
            test_step.dependOn(&b.addRunArtifact(gpu_detect_tests).step);
        }
    }

    // CLI tests (needs imports)
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "control", .module = control_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // KMS tests (Linux only — SCM_RIGHTS, DMA-BUF protocol)
    if (builtin.os.tag == .linux) {
        const protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/linux/kms/protocol.zig"),
            .target = target,
            .optimize = optimize,
        });

        const protocol_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/linux/kms/protocol.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(protocol_tests).step);

        const ipc_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/linux/kms/ipc.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "protocol", .module = protocol_mod },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(ipc_tests).step);
    }

    // Tests that need libdatachannel linked
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/session.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    session_tests.root_module.addIncludePath(b.path("libdatachannel/include"));
    shared_defs.linkDatachannel(b, session_tests);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);

    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/daemon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "control", .module = control_mod },
                .{ .name = "app_share", .module = platform_mods.app_share },
                .{ .name = "terminal_share", .module = terminal_share_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (platform_mods.gpu_detect) |gd_mod| {
        daemon_tests.root_module.addImport("gpu_detect", gd_mod);
    }
    shared_defs.linkDatachannel(b, daemon_tests);
    test_step.dependOn(&b.addRunArtifact(daemon_tests).step);

    const terminal_share_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/terminal_share.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "session", .module = session_mod },
                .{ .name = "osc_parser", .module = osc_parser_mod },
            },
        }),
    });
    terminal_share_tests.root_module.addIncludePath(b.path("libdatachannel/include"));
    shared_defs.linkDatachannel(b, terminal_share_tests);
    test_step.dependOn(&b.addRunArtifact(terminal_share_tests).step);

    // Property tests (minish)
    const minish_dep = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    });

    // protocol.zig is pure Zig structs (no platform deps) — safe to compile everywhere
    const protocol_mod_for_props = b.createModule(.{
        .root_source_file = b.path("src/linux/kms/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const prop_exe = b.addExecutable(.{
        .name = "prop-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/prop_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minish", .module = minish_dep.module("minish") },
                .{ .name = "input_protocol", .module = input_protocol_mod },
                .{ .name = "protocol", .module = protocol_mod_for_props },
            },
        }),
    });

    const run_prop = b.addRunArtifact(prop_exe);
    const prop_step = b.step("prop-test", "Run property-based tests");
    prop_step.dependOn(&run_prop.step);
    test_step.dependOn(&run_prop.step);

    // ── Static analysis (zwanzig) ────────────────────────────────────────
    const analyze_step = b.step("analyze", "Run zwanzig static analyzer on src/");
    const zwanzig_dep = b.dependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    });
    const zwanzig_exe = zwanzig_dep.artifact("zwanzig");
    const zwanzig_run = b.addRunArtifact(zwanzig_exe);
    zwanzig_run.addArgs(&.{ "--do", "store-violations-engine" });
    zwanzig_run.addArgs(&.{ "--do", "unreachable-code-engine" });
    zwanzig_run.addDirectoryArg(b.path("src"));
    analyze_step.dependOn(&zwanzig_run.step);

    // ── Rebuild libdatachannel static libs ────────────────────────────────
    const rebuild_step = b.step("rebuild-libs", "Rebuild libdatachannel static libs");
    rebuild_step.dependOn(platform.buildRebuildLibs(b));
}

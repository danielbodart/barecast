const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options (single shared module to avoid duplicate module errors) ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);
    const build_options_mod = options.createModule();

    // --- Shared modules ---
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    // --- NvFBC module (X11 + GL for GLX context) ---
    const nvfbc_mod = b.createModule(.{
        .root_source_file = b.path("src/nvfbc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nvfbc_mod.linkSystemLibrary("x11", .{});
    nvfbc_mod.linkSystemLibrary("gl", .{});

    // --- Input protocol module (wire protocol, pure data) ---
    const input_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/input_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- OSC parser module (terminal title extraction from PTY stream) ---
    const osc_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/osc_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Keymap module (KeyboardEvent.code → Linux keycode) ---
    const keymap_mod = b.createModule(.{
        .root_source_file = b.path("src/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Viewer state module (per-viewer cursors, drawing paths) ---
    const viewer_state_mod = b.createModule(.{
        .root_source_file = b.path("src/viewer_state.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Encode pipeline modules ---
    const cuda_mod = b.createModule(.{
        .root_source_file = b.path("src/cuda.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const nvenc_mod = b.createModule(.{
        .root_source_file = b.path("src/nvenc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cuda", .module = cuda_mod },
        },
    });

    const ivf_mod = b.createModule(.{
        .root_source_file = b.path("src/ivf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Session module (multi-viewer WebRTC, replaces webrtc module) ---
    const session_mod = b.createModule(.{
        .root_source_file = b.path("src/session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "input_protocol", .module = input_protocol_mod },
            .{ .name = "viewer_state", .module = viewer_state_mod },
        },
    });
    session_mod.addIncludePath(b.path("libdatachannel/include"));

    // --- Session recorder module (chunked IVF recording + diagnostics) ---
    const session_recorder_mod = b.createModule(.{
        .root_source_file = b.path("src/session_recorder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ivf", .module = ivf_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const encoder_mod = b.createModule(.{
        .root_source_file = b.path("src/encoder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nvfbc", .module = nvfbc_mod },
            .{ .name = "cuda", .module = cuda_mod },
            .{ .name = "nvenc", .module = nvenc_mod },
            .{ .name = "ivf", .module = ivf_mod },
            .{ .name = "session", .module = session_mod },
            .{ .name = "session_recorder", .module = session_recorder_mod },
        },
    });

    // --- Control protocol module (daemon ↔ CLI wire format) ---
    const control_mod = b.createModule(.{
        .root_source_file = b.path("src/control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- Headless display module (manages headless Xorg lifecycle) ---
    const headless_display_mod = b.createModule(.{
        .root_source_file = b.path("src/headless_display.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- Window manager module (minimal WM for headless app sharing) ---
    const window_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/window_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_manager_mod.linkSystemLibrary("x11", .{});

    // --- XTEST input module (input injection for headless app sharing) ---
    const xtest_input_mod = b.createModule(.{
        .root_source_file = b.path("src/xtest_input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = session_mod },
        },
    });
    xtest_input_mod.linkSystemLibrary("x11", .{});
    xtest_input_mod.linkSystemLibrary("xtst", .{});

    // --- App share module (headless display + NvFBC capture pipeline) ---
    const app_share_mod = b.createModule(.{
        .root_source_file = b.path("src/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nvfbc", .module = nvfbc_mod },
            .{ .name = "encoder", .module = encoder_mod },
            .{ .name = "control", .module = control_mod },
            .{ .name = "session", .module = session_mod },
            .{ .name = "viewer_state", .module = viewer_state_mod },
            .{ .name = "xtest_input", .module = xtest_input_mod },
            .{ .name = "headless_display", .module = headless_display_mod },
            .{ .name = "window_manager", .module = window_manager_mod },
            .{ .name = "session_recorder", .module = session_recorder_mod },
        },
    });

    // --- Terminal share module (PTY management + WebRTC data channel) ---
    const terminal_share_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "session", .module = session_mod },
            .{ .name = "osc_parser", .module = osc_parser_mod },
        },
    });

    // --- Daemon module (socket listener, session manager) ---
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "control", .module = control_mod },
            .{ .name = "app_share", .module = app_share_mod },
            .{ .name = "terminal_share", .module = terminal_share_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // --- CLI module (subcommand parser, socket client) ---
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "control", .module = control_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // --- zerocast (main binary, unprivileged) ---
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

    // Static link libdatachannel and its dependencies
    exe.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    exe.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    exe.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    exe.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkLibCpp();

    b.installArtifact(exe);

    // --- zerocast-kms (privileged helper, CAP_SYS_ADMIN) ---
    const drm_mod = b.createModule(.{
        .root_source_file = b.path("src/drm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drm_mod.linkSystemLibrary("libdrm", .{});

    const kms_exe = b.addExecutable(.{
        .name = "zerocast-kms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kms.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "ipc", .module = ipc_mod },
                .{ .name = "drm", .module = drm_mod },
            },
        }),
    });
    kms_exe.linkLibC();

    b.installArtifact(kms_exe);

    const xorg_exe = b.addExecutable(.{
        .name = "zerocast-xorg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xorg.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(xorg_exe);

    // --- fpscap.so (LD_PRELOAD frame rate cap for headless OpenGL apps) ---
    const fpscap = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "fpscap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fpscap.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(fpscap);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zerocast");
    run_step.dependOn(&run_cmd.step);

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");

    // Control protocol tests (JSON roundtrip, socket path)
    const control_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/control.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_control_tests = b.addRunArtifact(control_tests);
    test_step.dependOn(&run_control_tests.step);

    // Daemon tests (socket bind/accept, dispatch)
    // The daemon imports app_share which transitively depends on session
    // (libdatachannel), so we need the include path + static libs.
    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "control", .module = control_mod },
                .{ .name = "app_share", .module = app_share_mod },
                .{ .name = "terminal_share", .module = terminal_share_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    daemon_tests.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    daemon_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    daemon_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    daemon_tests.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    daemon_tests.linkSystemLibrary("ssl");
    daemon_tests.linkSystemLibrary("crypto");
    daemon_tests.linkLibCpp();
    const run_daemon_tests = b.addRunArtifact(daemon_tests);
    test_step.dependOn(&run_daemon_tests.step);

    // Terminal share tests (PTY helpers, asciinema format)
    const terminal_share_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_share.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "session", .module = session_mod },
                .{ .name = "osc_parser", .module = osc_parser_mod },
            },
        }),
    });
    terminal_share_tests.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    terminal_share_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    terminal_share_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    terminal_share_tests.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    terminal_share_tests.addIncludePath(b.path("libdatachannel/include"));
    terminal_share_tests.linkSystemLibrary("ssl");
    terminal_share_tests.linkSystemLibrary("crypto");
    terminal_share_tests.linkLibCpp();
    const run_terminal_share_tests = b.addRunArtifact(terminal_share_tests);
    test_step.dependOn(&run_terminal_share_tests.step);

    // OSC parser tests (terminal title extraction)
    const osc_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/osc_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_osc_parser_tests = b.addRunArtifact(osc_parser_tests);
    test_step.dependOn(&run_osc_parser_tests.step);

    // CLI tests (argument parsing, geometry detection)
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "control", .module = control_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // Protocol tests
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    // IPC tests (SCM_RIGHTS roundtrip via socketpair — no DRM needed)
    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    test_step.dependOn(&run_ipc_tests.step);

    // IVF tests
    const ivf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ivf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ivf_tests = b.addRunArtifact(ivf_tests);
    test_step.dependOn(&run_ivf_tests.step);

    // Input protocol tests (wire format decode/encode — pure data, no I/O)
    const input_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input_protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_input_protocol_tests = b.addRunArtifact(input_protocol_tests);
    test_step.dependOn(&run_input_protocol_tests.step);

    // Keymap tests (KeyboardEvent.code → Linux keycode lookup)
    const keymap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keymap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_keymap_tests = b.addRunArtifact(keymap_tests);
    test_step.dependOn(&run_keymap_tests.step);

    // Viewer state tests (registry, cursors, drawing paths)
    const viewer_state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer_state.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_viewer_state_tests = b.addRunArtifact(viewer_state_tests);
    test_step.dependOn(&run_viewer_state_tests.step);

    // Session tests (JSON helpers, peer routing — no network/GPU needed)
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    session_tests.root_module.addIncludePath(b.path("libdatachannel/include"));
    session_tests.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    session_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    session_tests.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    session_tests.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    session_tests.linkSystemLibrary("ssl");
    session_tests.linkSystemLibrary("crypto");
    session_tests.linkLibCpp();
    const run_session_tests = b.addRunArtifact(session_tests);
    test_step.dependOn(&run_session_tests.step);

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
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "input_protocol", .module = input_protocol_mod },
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
    zwanzig_run.addArgs(&.{ "--do", "unreachable-code-engine" });
    zwanzig_run.addDirectoryArg(b.path("src"));
    analyze_step.dependOn(&zwanzig_run.step);

    // --- Rebuild libdatachannel static libs (cmake → .zig-cache/cmake/) ---
    const rebuild_step = b.step("rebuild-libs", "Rebuild libdatachannel static libs");

    const cmake_build_dir = ".zig-cache/cmake";

    // Zig cc/c++ wrappers — cmake needs compiler scripts that resolve to zig cc/c++.
    // This ensures the static .a files use libc++ ABI, matching Zig's native linker.
    const zig_cc_path = b.pathJoin(&.{ b.build_root.path orelse ".", ".zig-cache/bin/zig-cc" });
    const zig_cxx_path = b.pathJoin(&.{ b.build_root.path orelse ".", ".zig-cache/bin/zig-c++" });

    const cmake_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "libdatachannel",
        "-B",
        cmake_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DNO_EXAMPLES=ON",
        "-DNO_TESTS=ON",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    });
    cmake_configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s}", .{zig_cc_path}));
    cmake_configure.addArg(b.fmt("-DCMAKE_CXX_COMPILER={s}", .{zig_cxx_path}));

    const cmake_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "--parallel",
    });
    cmake_build.step.dependOn(&cmake_configure.step);

    rebuild_step.dependOn(&cmake_build.step);
}

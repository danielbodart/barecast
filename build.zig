const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);

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

    // --- Overlay module (X11 region indicator) ---
    const overlay_mod = b.createModule(.{
        .root_source_file = b.path("src/overlay.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    overlay_mod.linkSystemLibrary("x11", .{});
    overlay_mod.addImport("nvfbc", nvfbc_mod);

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
    });
    session_mod.addIncludePath(b.path("libdatachannel/include"));

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
                .{ .name = "nvfbc", .module = nvfbc_mod },
                .{ .name = "encoder", .module = encoder_mod },
                .{ .name = "ivf", .module = ivf_mod },
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "ipc", .module = ipc_mod },
                .{ .name = "kms_client", .module = b.createModule(.{
                    .root_source_file = b.path("src/kms_client.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "protocol", .module = protocol_mod },
                        .{ .name = "ipc", .module = ipc_mod },
                    },
                }) },
                .{ .name = "session", .module = session_mod },
                .{ .name = "overlay", .module = overlay_mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);
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

    // Main module tests — only needs nvfbc for the Box type used by parseGeometry.
    // Other imports (encoder, session, overlay) are lazily resolved and not
    // referenced by any test block.
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nvfbc", .module = nvfbc_mod },
            },
        }),
    });
    main_tests.root_module.addOptions("build_options", options);
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

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

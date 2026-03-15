const std = @import("std");
const shared_defs = @import("build_shared.zig");

/// Create Linux-specific modules and return the platform module set.
pub fn buildPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) shared_defs.PlatformModules {
    // --- NvFBC module (X11 + GL for GLX context) ---
    const nvfbc_mod = b.createModule(.{
        .root_source_file = b.path("src/nvfbc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nvfbc_mod.linkSystemLibrary("x11", .{});
    nvfbc_mod.linkSystemLibrary("gl", .{});

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
            .{ .name = "codec", .module = shared.codec },
        },
    });

    // --- NVENC encoder backend (CUDA + NVENC, implements EncodeBackend) ---
    const encoder_nvenc_mod = b.createModule(.{
        .root_source_file = b.path("src/encoder_nvenc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cuda", .module = cuda_mod },
            .{ .name = "nvenc", .module = nvenc_mod },
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "encoder", .module = shared.encoder },
        },
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
            .{ .name = "keymap", .module = shared.keymap },
            .{ .name = "session", .module = shared.session },
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
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "encoder_nvenc", .module = encoder_nvenc_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "xtest_input", .module = xtest_input_mod },
            .{ .name = "headless_display", .module = headless_display_mod },
            .{ .name = "window_manager", .module = window_manager_mod },
            .{ .name = "session_recorder", .module = shared.session_recorder },
        },
    });

    return .{ .app_share = app_share_mod };
}

/// Install Linux-specific extra binaries (zerocast-kms, zerocast-xorg, fpscap.so).
pub fn buildExtraArtifacts(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) void {
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
                .{ .name = "protocol", .module = shared.protocol },
                .{ .name = "ipc", .module = shared.ipc },
                .{ .name = "drm", .module = drm_mod },
            },
        }),
    });
    kms_exe.linkLibC();
    b.installArtifact(kms_exe);

    // --- zerocast-xorg (setuid Xorg launcher) ---
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
}

/// Create the cmake rebuild-libs step for libdatachannel.
pub fn buildRebuildLibs(b: *std.Build) *std.Build.Step {
    const cmake_build_dir = ".zig-cache/cmake";

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

    return &cmake_build.step;
}

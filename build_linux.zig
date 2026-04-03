const std = @import("std");
const shared_defs = @import("build_shared.zig");

/// Create Linux-specific modules and return the platform module set.
pub fn buildPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) shared_defs.PlatformModules {
    // --- Keymap module (evdev keycodes) ---
    const keymap_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- NvFBC module (X11 + GL for GLX context) ---
    const nvfbc_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/nvfbc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nvfbc_mod.linkSystemLibrary("x11", .{});
    nvfbc_mod.linkSystemLibrary("gl", .{});

    // --- Encode pipeline modules ---
    const cuda_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/cuda.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const nvenc_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/nvenc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cuda", .module = cuda_mod },
            .{ .name = "codec", .module = shared.codec },
        },
    });

    // --- Encoder backend (CUDA + NVENC, implements EncodeBackend) ---
    const encoder_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/encoder_backend.zig"),
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
        .root_source_file = b.path("src/linux/x11/headless_display.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- Window manager module (minimal WM for headless app sharing) ---
    const window_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/window_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_manager_mod.linkSystemLibrary("x11", .{});

    // --- Input module (XTEST input injection for headless app sharing) ---
    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = shared.session },
        },
    });
    input_mod.linkSystemLibrary("x11", .{});
    input_mod.linkSystemLibrary("xtst", .{});

    // --- App share module (headless display + NvFBC capture pipeline) ---
    const app_share_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/x11/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nvfbc", .module = nvfbc_mod },
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "encoder_backend", .module = encoder_backend_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "input", .module = input_mod },
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
    _ = shared;

    // --- KMS protocol and IPC modules (Linux-only) ---
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/kms/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/kms/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    // --- zerocast-kms (privileged helper, CAP_SYS_ADMIN) ---
    const drm_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/kms/drm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drm_mod.linkSystemLibrary("libdrm", .{});

    const kms_exe = b.addExecutable(.{
        .name = "zerocast-kms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux/kms/main.zig"),
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

    // --- zerocast-xorg (setuid Xorg launcher) ---
    const xorg_exe = b.addExecutable(.{
        .name = "zerocast-xorg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux/x11/xorg.zig"),
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
            .root_source_file = b.path("src/linux/fpscap.zig"),
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

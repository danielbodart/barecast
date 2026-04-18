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
        .root_source_file = b.path("src/linux/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- VA-API encoder backend (Intel QSV / AMD VCN) ---
    const vaapi_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/vaapi/vaapi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "codec", .module = shared.codec },
        },
    });
    vaapi_mod.linkSystemLibrary("libva", .{});
    vaapi_mod.linkSystemLibrary("libva-drm", .{});
    vaapi_mod.addIncludePath(b.path("src/linux/vaapi"));
    vaapi_mod.addCSourceFile(.{ .file = b.path("src/linux/vaapi/hevc_params.c") });

    const vaapi_encoder_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/vaapi/encoder_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaapi", .module = vaapi_mod },
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "encoder", .module = shared.encoder },
        },
    });

    // --- Embedded Wayland compositor (wlroots headless) ---
    const compositor_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/compositor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compositor_mod.addIncludePath(b.path("wlroots/include"));
    compositor_mod.addIncludePath(b.path("libs/wlroots/include"));
    compositor_mod.addIncludePath(b.path("libs/wlroots/protocol"));
    compositor_mod.addIncludePath(b.path("src/linux/wayland"));
    compositor_mod.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    compositor_mod.addObjectFile(b.path("libs/wlroots/libwlroots.a"));
    // C helper to extract GL RBO from wlroots internal structs (NVIDIA path)
    compositor_mod.addCSourceFile(.{ .file = b.path("src/linux/wayland/gles2_helper.c"), .flags = &.{} });
    compositor_mod.linkSystemLibrary("wayland-server", .{});
    compositor_mod.linkSystemLibrary("wayland-client", .{});
    compositor_mod.linkSystemLibrary("pixman-1", .{});
    compositor_mod.linkSystemLibrary("egl", .{});
    compositor_mod.linkSystemLibrary("glesv2", .{});
    compositor_mod.linkSystemLibrary("gbm", .{});
    compositor_mod.linkSystemLibrary("libdrm", .{});
    compositor_mod.linkSystemLibrary("xkbcommon", .{});

    // --- NVIDIA CUDA module for Wayland (GL renderbuffer interop) ---
    const wayland_cuda_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/cuda.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- NVENC module (NVIDIA hardware encoder via libnvidia-encode) ---
    const wayland_nvenc_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/nvenc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cuda", .module = wayland_cuda_mod },
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "control", .module = shared.control },
        },
    });

    // --- NVENC encoder backend for Wayland (CUDA GL interop + NVENC) ---
    const wayland_nvenc_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/nvenc_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cuda", .module = wayland_cuda_mod },
            .{ .name = "nvenc", .module = wayland_nvenc_mod },
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "control", .module = shared.control },
        },
    });

    // --- Wayland input module (virtual keyboard + pointer via wlr_seat) ---
    const wayland_input_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = shared.session },
        },
    });
    wayland_input_mod.addIncludePath(b.path("wlroots/include"));
    wayland_input_mod.addIncludePath(b.path("libs/wlroots/include"));
    wayland_input_mod.addIncludePath(b.path("libs/wlroots/protocol"));
    wayland_input_mod.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    wayland_input_mod.addObjectFile(b.path("libs/wlroots/libwlroots.a"));
    wayland_input_mod.linkSystemLibrary("wayland-server", .{});
    wayland_input_mod.linkSystemLibrary("xkbcommon", .{});
    wayland_input_mod.linkSystemLibrary("pixman-1", .{});

    // --- Wayland app share (compositor + VA-API or NVENC encoder pipeline) ---
    const wayland_app_share_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "compositor", .module = compositor_mod },
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "vaapi_encoder_backend", .module = vaapi_encoder_backend_mod },
            .{ .name = "nvenc_backend", .module = wayland_nvenc_backend_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "session_recorder", .module = shared.session_recorder },
            .{ .name = "wayland_input", .module = wayland_input_mod },
            .{ .name = "debounce", .module = shared.debounce },
            .{ .name = "clock", .module = shared.clock },
        },
    });

    // --- GPU auto-detection module (sysfs + CUDA/VA-API probing) ---
    const gpu_detect_mod = b.createModule(.{
        .root_source_file = b.path("src/linux/gpu_detect.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "nvenc", .module = wayland_nvenc_mod },
        },
    });

    return .{
        .app_share = wayland_app_share_mod,
        .gpu_detect = gpu_detect_mod,
        .compositor = compositor_mod,
    };
}

/// Install Linux-specific extra binaries (zerocast-kms).
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

}

/// Create the cmake rebuild-libs step: libdatachannel + SVT-AV1 static libs.
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

    // SVT-AV1: AOMediaCodec reference AV1 software encoder. Vendored as
    // submodule at ./SVT-AV1. Pure C + ASM_NASM, builds with the same
    // zig cc shim as libdatachannel for consistent toolchain. Produces a
    // static libSvtAv1Enc.a consumed by the SW EncodeBackend adapter.
    const svt_build_dir = ".zig-cache/cmake-svt";

    const svt_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "SVT-AV1",
        "-B",
        svt_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_APPS=OFF",
        "-DBUILD_ENC=OFF",
        "-DBUILD_DEC=OFF",
        "-DBUILD_TESTING=OFF",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        // Pure-C build (no NASM/yasm assembler required). Slower than the
        // optimized asm path but portable and adequate for a software-fallback
        // encoder primarily used for GPU-free tests.
        "-DCOMPILE_C_ONLY=ON",
        // Zig cc treats -Wdate-time as an error by default; SVT-AV1's
        // enc_handle.c uses __DATE__/__TIME__. Suppress to compile clean.
        "-DCMAKE_C_FLAGS=-Wno-date-time",
    });
    svt_configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s}", .{zig_cc_path}));

    const svt_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        svt_build_dir,
        "--config",
        "Release",
        "--target",
        "SvtAv1Enc",
        "--parallel",
    });
    svt_build.step.dependOn(&svt_configure.step);
    // Chain SVT-AV1 after libdatachannel so the whole rebuild-libs step
    // exposes a single head to the caller (build.zig).
    svt_configure.step.dependOn(&cmake_build.step);

    return &svt_build.step;
}

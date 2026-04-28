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
        .root_source_file = b.path("packages/zerocast/src/linux/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Embedded Wayland compositor (wlroots headless) ---
    const compositor_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/compositor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compositor_mod.addIncludePath(b.path("packages/wlroots/include"));
    compositor_mod.addIncludePath(b.path("libs/wlroots/include"));
    compositor_mod.addIncludePath(b.path("libs/wlroots/protocol"));
    compositor_mod.addIncludePath(b.path("packages/zerocast/src/linux/wayland"));
    compositor_mod.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    compositor_mod.addObjectFile(b.path("libs/wlroots/libwlroots.a"));
    // C helper to extract GL RBO from wlroots internal structs (NVIDIA path)
    compositor_mod.addCSourceFile(.{ .file = b.path("packages/zerocast/src/linux/wayland/gles2_helper.c"), .flags = &.{} });
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
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/cuda.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- NVENC module (NVIDIA hardware encoder via libnvidia-encode) ---
    const wayland_nvenc_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/nvenc.zig"),
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
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/nvenc_backend.zig"),
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

    // SVT-AV1 software backend + YUV downloader. The encoder module is
    // shared (see build.zig); the downloader is Wayland-specific because
    // it does GL readback on the compositor's FBO (T-010).
    const frame_download_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/frame_download.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "yuv", .module = shared.yuv },
        },
    });
    frame_download_mod.linkSystemLibrary("glesv2", .{});

    // --- Wayland input module (virtual keyboard + pointer via wlr_seat) ---
    const wayland_input_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = shared.session },
        },
    });
    wayland_input_mod.addIncludePath(b.path("packages/wlroots/include"));
    wayland_input_mod.addIncludePath(b.path("libs/wlroots/include"));
    wayland_input_mod.addIncludePath(b.path("libs/wlroots/protocol"));
    wayland_input_mod.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    wayland_input_mod.addObjectFile(b.path("libs/wlroots/libwlroots.a"));
    wayland_input_mod.linkSystemLibrary("wayland-server", .{});
    wayland_input_mod.linkSystemLibrary("xkbcommon", .{});
    wayland_input_mod.linkSystemLibrary("pixman-1", .{});

    // --- GPU auto-detection module (sysfs + CUDA/VA-API probing) ---
    // Declared before app_share so app_share can import it for its
    // probe-driven backend selection (T-018).
    const gpu_detect_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/gpu_detect.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "codec", .module = shared.codec },
            .{ .name = "nvenc", .module = wayland_nvenc_mod },
        },
    });

    // --- Wayland app share (compositor + NVENC/SVT-AV1 encoder pipeline) ---
    const wayland_app_share_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/wayland/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "compositor", .module = compositor_mod },
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "nvenc_backend", .module = wayland_nvenc_backend_mod },
            .{ .name = "svt_backend", .module = shared.svt_backend },
            .{ .name = "frame_download", .module = frame_download_mod },
            .{ .name = "gpu_detect", .module = gpu_detect_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "session_recorder", .module = shared.session_recorder },
            .{ .name = "wayland_input", .module = wayland_input_mod },
            .{ .name = "debounce", .module = shared.debounce },
            .{ .name = "clock", .module = shared.clock },
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
        .root_source_file = b.path("packages/zerocast/src/linux/kms/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/kms/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    // --- zerocast-kms (privileged helper, CAP_SYS_ADMIN) ---
    const drm_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/linux/kms/drm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drm_mod.linkSystemLibrary("libdrm", .{});

    const kms_exe = b.addExecutable(.{
        .name = "zerocast-kms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zerocast/src/linux/kms/main.zig"),
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


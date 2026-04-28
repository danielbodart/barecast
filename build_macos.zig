const std = @import("std");
const shared_defs = @import("build_shared.zig");

/// Create macOS-specific modules and return the platform module set.
pub fn buildPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) shared_defs.PlatformModules {
    // --- macOS CPU-side frame downloader (BGRA → I420 via shared yuv) ---
    // Consumed by app_share; takes a CVPixelBuffer pointer, returns an
    // I420 slice the encoder can plant straight into SvtBackend.
    const frame_download_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/macos/frame_download.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "yuv", .module = shared.yuv },
        },
    });
    frame_download_mod.addIncludePath(b.path("packages/zerocast/src/macos"));

    // --- macOS keymap (W3C KeyboardEvent.code → macOS virtual keycodes) ---
    const keymap_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/macos/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Input handler (mouse + keyboard injection via CoreGraphics) ---
    const input_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/macos/input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = shared.session },
        },
    });
    input_mod.addIncludePath(b.path("packages/zerocast/src/macos"));
    input_mod.linkFramework("CoreGraphics", .{});
    input_mod.linkFramework("ApplicationServices", .{});

    // --- App share (ScreenCaptureKit capture → SVT-AV1 encode → WebRTC) ---
    const app_share_mod = b.createModule(.{
        .root_source_file = b.path("packages/zerocast/src/macos/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "svt_backend", .module = shared.svt_backend },
            .{ .name = "frame_download", .module = frame_download_mod },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "input", .module = input_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session_recorder", .module = shared.session_recorder },
            .{ .name = "clock", .module = shared.clock },
        },
    });
    app_share_mod.addIncludePath(b.path("packages/zerocast/src/macos"));
    app_share_mod.addCSourceFile(.{
        .file = b.path("packages/zerocast/src/macos/screen_capture.m"),
        .flags = &.{"-fobjc-arc"},
    });
    app_share_mod.addCSourceFile(.{
        .file = b.path("packages/zerocast/src/macos/virtual_display.m"),
        .flags = &.{"-fobjc-arc"},
    });
    app_share_mod.linkFramework("ScreenCaptureKit", .{});
    app_share_mod.linkFramework("CoreMedia", .{});
    app_share_mod.linkFramework("CoreVideo", .{});
    app_share_mod.linkFramework("CoreGraphics", .{});
    app_share_mod.linkFramework("Foundation", .{});
    app_share_mod.linkFramework("AppKit", .{});
    app_share_mod.linkFramework("ApplicationServices", .{});
    app_share_mod.linkSystemLibrary("objc", .{});

    return .{ .app_share = app_share_mod };
}

/// Install macOS-specific extra binaries.
pub fn buildExtraArtifacts(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) void {
    _ = b;
    _ = target;
    _ = optimize;
    _ = shared;
    // No extra binaries on macOS — virtual display runs in-process.
}


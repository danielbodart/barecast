const std = @import("std");
const shared_defs = @import("build_shared.zig");

/// Create macOS-specific modules and return the platform module set.
pub fn buildPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: shared_defs.SharedModules,
) shared_defs.PlatformModules {
    // --- VideoToolbox encoder backend (HEVC via VTCompressionSession) ---
    const encoder_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/encoder_backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "encoder", .module = shared.encoder },
        },
    });
    encoder_backend_mod.addIncludePath(b.path("src/macos"));
    encoder_backend_mod.addCSourceFile(.{
        .file = b.path("src/macos/videotoolbox.m"),
        .flags = &.{"-fobjc-arc"},
    });
    encoder_backend_mod.linkFramework("VideoToolbox", .{});
    encoder_backend_mod.linkFramework("CoreMedia", .{});
    encoder_backend_mod.linkFramework("CoreVideo", .{});
    encoder_backend_mod.linkSystemLibrary("objc", .{});

    // --- macOS keymap (W3C KeyboardEvent.code → macOS virtual keycodes) ---
    const keymap_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/keymap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Input handler (mouse + keyboard injection via CoreGraphics) ---
    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/input.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "keymap", .module = keymap_mod },
            .{ .name = "session", .module = shared.session },
        },
    });
    input_mod.addIncludePath(b.path("src/macos"));
    input_mod.linkFramework("CoreGraphics", .{});
    input_mod.linkFramework("ApplicationServices", .{});

    // --- App share module (ScreenCaptureKit capture + VideoToolbox encode + WebRTC) ---
    const app_share_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/app_share.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "encoder", .module = shared.encoder },
            .{ .name = "encoder_backend", .module = encoder_backend_mod },
            .{ .name = "session", .module = shared.session },
            .{ .name = "viewer_state", .module = shared.viewer_state },
            .{ .name = "input", .module = input_mod },
            .{ .name = "control", .module = shared.control },
            .{ .name = "session_recorder", .module = shared.session_recorder },
        },
    });
    app_share_mod.addIncludePath(b.path("src/macos"));
    app_share_mod.addCSourceFile(.{
        .file = b.path("src/macos/screen_capture.m"),
        .flags = &.{"-fobjc-arc"},
    });
    app_share_mod.addCSourceFile(.{
        .file = b.path("src/macos/virtual_display.m"),
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

/// Create the cmake rebuild-libs step for libdatachannel on macOS.
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

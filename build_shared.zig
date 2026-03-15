const std = @import("std");

/// All shared (platform-independent) modules, passed into platform build functions.
pub const SharedModules = struct {
    build_options: *std.Build.Module,
    protocol: *std.Build.Module,
    ipc: *std.Build.Module,
    input_protocol: *std.Build.Module,
    osc_parser: *std.Build.Module,
    keymap: *std.Build.Module,
    viewer_state: *std.Build.Module,
    ivf: *std.Build.Module,
    session: *std.Build.Module,
    session_recorder: *std.Build.Module,
    encoder: *std.Build.Module,
    codec: *std.Build.Module,
    terminal_share: *std.Build.Module,
    control: *std.Build.Module,
};

/// Platform-specific modules returned by platform build functions.
pub const PlatformModules = struct {
    app_share: *std.Build.Module,
};

/// Link libdatachannel and its static dependencies into an artifact.
/// Shared across the main binary and all test artifacts that transitively
/// depend on session.zig (which uses the libdatachannel C API).
pub fn linkDatachannel(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    artifact.linkSystemLibrary("ssl");
    artifact.linkSystemLibrary("crypto");
    artifact.linkLibCpp();
}
